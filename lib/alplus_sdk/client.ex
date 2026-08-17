defmodule AlplusSDK.Client do
  @moduledoc """
  Owns the in-memory event queue and the batch/flush timer. A `GenServer` is
  the right tool here (not a plain module) because the queue is live,
  mutable state shared across every caller in the host app and must be
  serialized: two concurrent `capture_exception/2` calls must not race on
  the same queue.

  Never raises into the caller: `capture_exception/2`/`capture_message/3`
  enqueue with a `GenServer.cast/2` (fire-and-forget, off the caller's
  request path) and every transport failure is caught inside this process
  and logged at `:debug`, never propagated.

  The actual HTTP send (`Req.post/1`, up to `:receive_timeout`) never runs
  inline in this GenServer's own message loop for an auto-triggered flush
  (batch-size threshold or the idle timer): it runs in a task under this
  client's own linked `Task.Supervisor`, so a slow/unreachable ingest
  endpoint cannot back up the mailbox `enqueue/2` casts pile into. An
  explicit `flush/2` call still waits for its own send to finish (bounded by
  its own timeout) -- that is the caller asking to know when the queue has
  drained, not an internal auto-flush.
  """

  use GenServer
  require Logger

  alias AlplusSDK.{Config, Dedup, Envelope, Id, Transport}

  @type name :: GenServer.name()

  @doc """
  Starts a client. `opts` accepts every `AlplusSDK.Config` field plus
  `:name` (default `AlplusSDK.Client`, the name every other `AlplusSDK`
  function assumes unless given `:name` explicitly).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Enqueues an already-built wire item. Fire-and-forget; never blocks the caller on network I/O."
  @spec enqueue(name(), map()) :: :ok
  def enqueue(name \\ __MODULE__, item) do
    # The caller pid travels with the item: the post-error log window
    # (issue #47) attributes after-lines to the process that captured.
    GenServer.cast(name, {:enqueue, item, self()})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Offers a log-line breadcrumb (issue #47) to every exception item this
  process captured that is still inside its post-error log window. Called
  by `AlplusSDK.LoggerHandler` from the logging process; a no-op with
  nothing pending. Fire-and-forget; never blocks or raises.
  """
  @spec notify_log_breadcrumb(name(), map()) :: :ok
  def notify_log_breadcrumb(name \\ __MODULE__, crumb) do
    GenServer.cast(name, {:log_breadcrumb, self(), crumb})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Enqueues an already-built session-outcome item (issue #12), batched off
  the request path exactly like `enqueue/2` but sent to `POST /e/sessions`
  on its own queue -- a session outcome never shares a batch with an error
  event, so a partial `/e/errors` failure can never affect session delivery
  or vice versa. Fire-and-forget; never blocks the caller.
  """
  @spec enqueue_session(name(), map()) :: :ok
  def enqueue_session(name \\ __MODULE__, item) do
    GenServer.cast(name, {:enqueue_session, item})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Forces an immediate send of whatever is queued. Returns `:ok` once the attempt (success or swallowed failure) completes, or `:timeout`."
  @spec flush(name(), timeout()) :: :ok | :timeout
  def flush(name \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(name, :flush, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
    :exit, _ -> :ok
  end

  @doc "Returns the resolved `%AlplusSDK.Config{}` (key redacted on inspect). Test/introspection helper."
  @spec config(name()) :: Config.t()
  def config(name \\ __MODULE__) do
    GenServer.call(name, :config)
  end

  @doc """
  Resolves an exception dedup signature against this client's cache (see
  `AlplusSDK.Dedup` for why the cache lives here). A cheap, purely
  in-memory `GenServer.call` -- never touches the network -- so it is safe
  to call from `AlplusSDK.capture_exception/2`'s own request path. If the
  client isn't running, dedup is skipped: `fresh_id` is returned as-is,
  same as every other "no client" fallback in this package.
  """
  @spec resolve_dedup(name(), Dedup.key(), String.t()) ::
          {:fresh, String.t()} | {:duplicate, String.t()}
  def resolve_dedup(name \\ __MODULE__, key, fresh_id) do
    GenServer.call(name, {:resolve_dedup, key, fresh_id})
  catch
    :exit, _ -> {:fresh, fresh_id}
  end

  # -- Server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Config.new(opts)
    {:ok, task_sup} = Task.Supervisor.start_link([])

    {:ok,
     %{
       config: config,
       queue: [],
       queued_bytes: 0,
       session_queue: [],
       session_queued_bytes: 0,
       timer: nil,
       task_sup: task_sup,
       dedup: %{},
       # ref => %{item, origin, appended} — exception items inside their
       # post-error log window (issue #47).
       pending: %{}
     }}
  end

  @impl true
  def handle_cast({:enqueue, _item, _origin}, %{config: %{enabled?: false}} = state) do
    {:noreply, state}
  end

  # An exception item enters the post-error log window (issue #47) instead
  # of the queue: it lingers `post_error_log_window_ms` so Logger lines its
  # origin process writes just after the error can join it. Everything
  # else (messages; window disabled) queues immediately.
  def handle_cast({:enqueue, item, origin}, state) do
    window = state.config.post_error_log_window_ms

    if window > 0 and item[:type] == "exception" do
      ref = make_ref()
      Process.send_after(self(), {:seal_pending, ref}, window)
      {:noreply, put_in(state.pending[ref], %{item: item, origin: origin, appended: 0})}
    else
      {:noreply, push_item(state, item)}
    end
  end

  @max_after_error_breadcrumbs 20
  @max_total_breadcrumbs 100

  def handle_cast({:log_breadcrumb, origin, crumb}, state) do
    pending =
      Map.new(state.pending, fn
        {ref, %{origin: ^origin, appended: appended} = entry}
        when appended < @max_after_error_breadcrumbs ->
          crumbs = entry.item[:breadcrumbs] || []

          if length(crumbs) < @max_total_breadcrumbs do
            marked =
              Map.update(crumb, :data, %{after_error: true}, &Map.put(&1, :after_error, true))

            item = Map.put(entry.item, :breadcrumbs, crumbs ++ [marked])
            {ref, %{entry | item: item, appended: appended + 1}}
          else
            {ref, entry}
          end

        {ref, entry} ->
          {ref, entry}
      end)

    {:noreply, %{state | pending: pending}}
  end

  def handle_cast({:enqueue_session, _item}, %{config: %{enabled?: false}} = state) do
    {:noreply, state}
  end

  # `session_queue` is a plain list, not a `SizedQueue` (unlike
  # `sdks/ruby/lib/alplus/worker.rb`'s bounded queue) -- this guard is its
  # equivalent bound, dropping the newest item (never blocking the caller)
  # once `:session_queue_max_items` is reached, so a sustained ingest
  # outage (every auto-flush failing, nothing ever draining the list)
  # cannot grow this GenServer's memory without limit.
  def handle_cast({:enqueue_session, _item}, state)
      when length(state.session_queue) >= state.config.session_queue_max_items do
    if state.config.debug,
      do:
        Logger.debug(
          "alplus_sdk: session queue full (max #{state.config.session_queue_max_items}); dropping session"
        )

    {:noreply, state}
  end

  def handle_cast({:enqueue_session, item}, state) do
    item_bytes = Envelope.byte_size_of(item)

    state = %{
      state
      | session_queue: [item | state.session_queue],
        session_queued_bytes: state.session_queued_bytes + item_bytes
    }

    cond do
      length(state.session_queue) >= state.config.batch_max_items or
          state.session_queued_bytes >= state.config.batch_max_bytes ->
        {:noreply, do_flush_async(cancel_timer(state))}

      state.timer == nil and state.config.flush_interval_ms > 0 ->
        {:noreply, schedule_timer(state)}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    # Seal the post-error log window first: flush means "send now with
    # whatever after-lines were collected so far", never "wait".
    state = seal_all_pending(state)
    {items, state} = drain(cancel_timer(state))
    {session_items, state} = drain_sessions(state)
    send_batch_sync(state.task_sup, state.config, items)
    send_session_batch_sync(state.task_sup, state.config, session_items)
    {:reply, :ok, state}
  end

  def handle_call(:config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:resolve_dedup, key, fresh_id}, _from, state) do
    now = System.system_time(:millisecond)
    {result, dedup} = Dedup.resolve(state.dedup, key, fresh_id, now)
    {:reply, result, %{state | dedup: dedup}}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    {:noreply, do_flush_async(%{state | timer: nil})}
  end

  def handle_info({:seal_pending, ref}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} -> {:noreply, state}
      {entry, pending} -> {:noreply, push_item(%{state | pending: pending}, entry.item)}
    end
  end

  # The shared enqueue tail: queue the item and apply the batch/timer rules.
  defp push_item(state, item) do
    item_bytes = Envelope.byte_size_of(item)
    state = %{state | queue: [item | state.queue], queued_bytes: state.queued_bytes + item_bytes}

    cond do
      length(state.queue) >= state.config.batch_max_items or
          state.queued_bytes >= state.config.batch_max_bytes ->
        do_flush_async(cancel_timer(state))

      state.timer == nil and state.config.flush_interval_ms > 0 ->
        schedule_timer(state)

      true ->
        state
    end
  end

  defp seal_all_pending(state) do
    state.pending
    |> Map.values()
    |> Enum.reduce(%{state | pending: %{}}, fn entry, acc -> push_item(acc, entry.item) end)
  end

  defp schedule_timer(state) do
    timer = Process.send_after(self(), :flush_timer, state.config.flush_interval_ms)
    %{state | timer: timer}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp drain(state) do
    items = Enum.reverse(state.queue)
    {items, %{state | queue: [], queued_bytes: 0}}
  end

  defp drain_sessions(state) do
    items = Enum.reverse(state.session_queue)
    {items, %{state | session_queue: [], session_queued_bytes: 0}}
  end

  # Auto-triggered flush (batch-size threshold, idle timer): fires the send
  # in a task under this client's own Task.Supervisor and returns
  # immediately, so a slow/down ingest endpoint never backs up this
  # GenServer's mailbox -- `enqueue/2`/`enqueue_session/2` casts must keep
  # being processed while a send is in flight.
  defp do_flush_async(%{queue: [], session_queue: []} = state), do: state

  defp do_flush_async(state) do
    {items, state} = drain(state)
    {session_items, state} = drain_sessions(state)
    send_batch_async(state.task_sup, state.config, items)
    send_session_batch_async(state.task_sup, state.config, session_items)
    state
  end

  defp send_batch_async(_task_sup, _config, []), do: :ok

  defp send_batch_async(task_sup, config, items) do
    start_async(task_sup, config, fn -> send_batch(config, items) end)
  end

  defp send_session_batch_async(_task_sup, _config, []), do: :ok

  defp send_session_batch_async(task_sup, config, items) do
    start_async(task_sup, config, fn -> send_session_batch(config, items) end)
  end

  defp start_async(task_sup, config, fun) do
    Task.Supervisor.start_child(task_sup, fun, restart: :temporary)
  rescue
    error ->
      if config.debug,
        do:
          Logger.debug(
            "alplus_sdk: failed to start flush task: #{Exception.format(:error, error, __STACKTRACE__)}"
          )

      :ok
  end

  # Explicit `flush/2` call: the caller is asking to know the queue drained,
  # so this waits (bounded by the task's own timeout) rather than firing
  # and forgetting like the auto-triggered path above.
  defp send_batch_sync(_task_sup, _config, []), do: :ok

  defp send_batch_sync(task_sup, config, items) do
    await_sync(task_sup, config, fn -> send_batch(config, items) end)
  end

  defp send_session_batch_sync(_task_sup, _config, []), do: :ok

  defp send_session_batch_sync(task_sup, config, items) do
    await_sync(task_sup, config, fn -> send_session_batch(config, items) end)
  end

  defp await_sync(task_sup, config, fun) do
    task_sup
    |> Task.Supervisor.async_nolink(fun)
    |> Task.await(config.receive_timeout + 1_000)
  catch
    :exit, _ ->
      if config.debug, do: Logger.debug("alplus_sdk: flush task did not complete in time")
      :ok
  end

  defp send_batch(config, items) do
    envelope = Envelope.build(config, items)
    body = Jason.encode!(envelope)

    if byte_size(body) > Config.max_envelope_bytes() do
      if config.debug,
        do: Logger.debug("alplus_sdk: dropping oversized envelope (#{length(items)} events)")

      :ok
    else
      Transport.post(config, body)
    end
  rescue
    error ->
      if config.debug,
        do:
          Logger.debug(
            "alplus_sdk: internal error while flushing: #{Exception.format(:error, error, __STACKTRACE__)}"
          )

      :ok
  end

  defp send_session_batch(config, items) do
    envelope = Envelope.build(config, items)
    body = Jason.encode!(envelope)

    if byte_size(body) > Config.max_envelope_bytes() do
      if config.debug,
        do:
          Logger.debug(
            "alplus_sdk: dropping oversized session envelope (#{length(items)} sessions)"
          )

      :ok
    else
      Transport.post_sessions(config, body)
    end
  rescue
    error ->
      if config.debug,
        do:
          Logger.debug(
            "alplus_sdk: internal error while flushing sessions: #{Exception.format(:error, error, __STACKTRACE__)}"
          )

      :ok
  end

  @doc false
  def generate_id, do: Id.generate()
end
