defmodule AlplusSDK.Client do
  @moduledoc false

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
    {integrations, opts} = Keyword.pop(opts, :integrations, [:logger, :phoenix])
    GenServer.start_link(__MODULE__, {name, integrations, opts}, name: name)
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
  end

  @doc """
  Offers a log-line breadcrumb (issue #47) to the most recent exception
  item this process captured that is still inside its post-error log
  window. Called by `AlplusSDK.LoggerHandler` from the logging process; a
  no-op with nothing pending. Fire-and-forget; never blocks or raises.
  """
  @spec notify_log_breadcrumb(name(), map()) :: :ok
  def notify_log_breadcrumb(name \\ __MODULE__, crumb) do
    GenServer.cast(name, {:log_breadcrumb, self(), crumb})
  rescue
    _ -> :ok
  end

  @doc """
  Whether this process currently has an exception item inside the
  post-error log window. `AlplusSDK.LoggerHandler` uses this so a
  `Logger.error/1` written just after a capture joins that event as a
  breadcrumb instead of becoming a second issue.
  """
  @spec has_pending_exception?(name()) :: boolean()
  def has_pending_exception?(name \\ __MODULE__) do
    GenServer.call(name, {:has_pending_exception?, self()})
  catch
    :exit, _ -> false
  end

  @doc """
  A duplicate `capture_exception/2` (same signature inside the dedup
  window) did not enqueue a new item. If this process's pending exception
  is that same event, keep the post-error window open so after-lines still
  join it. If it is a *different* event, seal it — otherwise later logs
  attach to the wrong issue.
  """
  @spec note_duplicate_capture(name(), String.t()) :: :ok
  def note_duplicate_capture(name \\ __MODULE__, existing_id) when is_binary(existing_id) do
    GenServer.cast(name, {:note_duplicate, self(), existing_id})
  rescue
    _ -> :ok
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

  @doc false
  def reset_dedup(name \\ __MODULE__) do
    GenServer.call(name, :reset_dedup)
  catch
    :exit, _ -> :ok
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
  def init({name, integrations, opts}) do
    config = Config.new(opts)
    {:ok, task_sup} = Task.Supervisor.start_link([])
    hooks = attach_host_hooks(name, integrations)

    {:ok,
     %{
       name: name,
       hooks: hooks,
       config: config,
       queue: [],
       queued_bytes: 0,
       session_queue: [],
       session_queued_bytes: 0,
       timer: nil,
       task_sup: task_sup,
       dedup: %{},
       # ref => %{item, origin, appended, seq} — exception items inside their
       # post-error log window (issue #47). `pending_seq` orders them so
       # after-error crumbs attach to the most recent origin, not a hash-map
       # iteration artifact.
       pending: %{},
       pending_seq: 0
     }}
  end

  @impl true
  def terminate(_reason, state) do
    try do
      state = seal_all_pending(state)
      {items, state} = drain(cancel_timer(state))
      {session_items, state} = drain_sessions(state)
      send_batch_sync(state.task_sup, state.config, items, state.name)
      send_session_batch_sync(state.task_sup, state.config, session_items, state.name)
    after
      detach_host_hooks(state.hooks)
    end

    :ok
  end

  @impl true
  def handle_cast({:enqueue, _item, _origin}, %{config: %{enabled?: false}} = state) do
    {:noreply, state}
  end

  # An exception item enters the post-error log window (issue #47) instead
  # of the queue: it lingers `post_error_log_window_ms` so Logger lines its
  # origin process writes just after the error can join it. A new exception
  # from the same origin seals the previous pending item first, so later
  # logs attach only to the most recent error, not every still-open window.
  # Everything else (messages; window disabled) queues immediately.
  def handle_cast({:enqueue, item, origin}, state) do
    window = state.config.post_error_log_window_ms

    if window > 0 and item[:type] == "exception" do
      state = seal_pending_for_origin(state, origin)
      ref = make_ref()
      seq = state.pending_seq + 1
      Process.send_after(self(), {:seal_pending, ref}, window)

      state = %{
        state
        | pending_seq: seq,
          pending:
            Map.put(state.pending, ref, %{item: item, origin: origin, appended: 0, seq: seq})
      }

      {:noreply, state}
    else
      {:noreply, push_item(state, item)}
    end
  end

  @max_after_error_breadcrumbs 20
  @max_total_breadcrumbs 100

  def handle_cast({:log_breadcrumb, origin, crumb}, state) do
    pending =
      case newest_pending_for(state.pending, origin) do
        {ref, %{appended: appended} = entry}
        when appended < @max_after_error_breadcrumbs ->
          crumbs = entry.item[:breadcrumbs] || []

          if length(crumbs) < @max_total_breadcrumbs do
            marked =
              Map.update(crumb, :data, %{after_error: true}, &Map.put(&1, :after_error, true))

            item = Map.put(entry.item, :breadcrumbs, crumbs ++ [marked])
            Map.put(state.pending, ref, %{entry | item: item, appended: appended + 1})
          else
            state.pending
          end

        _ ->
          state.pending
      end

    {:noreply, %{state | pending: pending}}
  end

  def handle_cast({:note_duplicate, origin, existing_id}, state) do
    case newest_pending_for(state.pending, origin) do
      {_ref, %{item: item}} ->
        if item[:id] == existing_id or item["id"] == existing_id do
          {:noreply, state}
        else
          {:noreply, seal_pending_for_origin(state, origin)}
        end

      nil ->
        {:noreply, state}
    end
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
    send_batch_sync(state.task_sup, state.config, items, state.name)
    send_session_batch_sync(state.task_sup, state.config, session_items, state.name)
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

  def handle_call({:has_pending_exception?, origin}, _from, state) do
    {:reply, newest_pending_for(state.pending, origin) != nil, state}
  end

  def handle_call(:reset_dedup, _from, state) do
    {:reply, :ok, %{state | dedup: %{}}}
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

  defp seal_pending_for_origin(state, origin) do
    {to_seal, keep} =
      Enum.split_with(state.pending, fn {_ref, entry} -> entry.origin == origin end)

    Enum.reduce(to_seal, %{state | pending: Map.new(keep)}, fn {_ref, entry}, acc ->
      push_item(acc, entry.item)
    end)
  end

  defp newest_pending_for(pending, origin) do
    pending
    |> Enum.filter(fn {_ref, entry} -> entry.origin == origin end)
    |> Enum.max_by(fn {_ref, entry} -> entry.seq end, fn -> nil end)
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
    send_batch_async(state.task_sup, state.config, items, state.name)
    send_session_batch_async(state.task_sup, state.config, session_items, state.name)
    state
  end

  defp send_batch_async(_task_sup, _config, [], _name), do: :ok

  defp send_batch_async(task_sup, config, items, name) do
    start_async(task_sup, config, fn -> send_batch(config, items, name) end)
  end

  defp send_session_batch_async(_task_sup, _config, [], _name), do: :ok

  defp send_session_batch_async(task_sup, config, items, name) do
    start_async(task_sup, config, fn -> send_session_batch(config, items, name) end)
  end

  defp start_async(task_sup, config, fun) do
    Task.Supervisor.start_child(task_sup, fun, restart: :temporary)
  catch
    kind, reason ->
      if config.debug,
        do:
          Logger.debug(
            "alplus_sdk: failed to start flush task: #{Exception.format(kind, reason, __STACKTRACE__)}"
          )

      :ok
  end

  # Explicit `flush/2` call: the caller is asking to know the queue drained,
  # so this waits (bounded by the task's own timeout) rather than firing
  # and forgetting like the auto-triggered path above.
  defp send_batch_sync(_task_sup, _config, [], _name), do: :ok

  defp send_batch_sync(task_sup, config, items, name) do
    await_sync(task_sup, config, fn -> send_batch(config, items, name) end)
  end

  defp send_session_batch_sync(_task_sup, _config, [], _name), do: :ok

  defp send_session_batch_sync(task_sup, config, items, name) do
    await_sync(task_sup, config, fn -> send_session_batch(config, items, name) end)
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

  defp send_batch(config, items, name) do
    envelope = Envelope.build(config, items)
    body = Jason.encode!(envelope)

    if byte_size(body) > Config.max_envelope_bytes() do
      if config.debug,
        do: Logger.debug("alplus_sdk: dropping oversized envelope (#{length(items)} events)")

      :ok
    else
      deliver_body(config, name, :errors, body, fn -> Transport.post(config, body) end)
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

  defp send_session_batch(config, items, name) do
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
      deliver_body(config, name, :sessions, body, fn -> Transport.post_sessions(config, body) end)
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

  defp deliver_body(%{test?: true}, name, kind, body, _http) do
    AlplusSDK.Test.record(name, kind, body)
    :ok
  end

  defp deliver_body(_config, _name, _kind, _body, http), do: http.()

  defp attach_host_hooks(name, integrations) do
    hooks = %{logger: nil, phoenix: nil}

    hooks =
      if :logger in integrations do
        handler_id = logger_handler_id(name)
        _ = :logger.remove_handler(handler_id)
        :ok = :logger.add_handler(handler_id, AlplusSDK.LoggerHandler, %{config: %{name: name}})
        %{hooks | logger: handler_id}
      else
        hooks
      end

    if :phoenix in integrations do
      handler_id = {:alplus_sdk_phoenix, name}
      AlplusSDK.Telemetry.attach_phoenix(name: name, handler_id: handler_id)
      %{hooks | phoenix: handler_id}
    else
      hooks
    end
  end

  defp detach_host_hooks(hooks) do
    if hooks.logger, do: :logger.remove_handler(hooks.logger)
    if hooks.phoenix, do: AlplusSDK.Telemetry.detach(hooks.phoenix)
    :ok
  end

  defp logger_handler_id(name), do: :"alplus_sdk_logger_#{inspect(name)}"

  @doc false
  def generate_id, do: Id.generate()
end
