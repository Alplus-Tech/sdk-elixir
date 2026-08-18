defmodule AlplusSDK do
  @moduledoc """
  Elixir client for AL+ Observe (`POST /e/errors`) and Monitor heartbeats.

  ## Setup

  Set `ALPLUS_KEY`. Add the child. Add the plug first in the endpoint.

      children = [
        {AlplusSDK, []},
        MyAppWeb.Endpoint
      ]

      # endpoint.ex
      plug AlplusSDK.Plug

  `start_link/1` attaches the OTP logger handler and Phoenix
  `[:phoenix, :error_rendered]` handler. Unhandled crashes are captured
  without wrapping call sites.

  Identify the current user after the plug:

      AlplusSDK.set_user(%{id: user.id, email: user.email})

  Capture a rescued exception when you handle it yourself:

      try do
        risky()
      rescue
        exception -> AlplusSDK.capture_exception(exception, stacktrace: __STACKTRACE__)
      end

  Env vars: `ALPLUS_KEY`, `ALPLUS_ENDPOINT`, `ALPLUS_ENVIRONMENT`,
  `ALPLUS_RELEASE`. Explicit `start_link/1` opts win.

  In test, start with `test: true` and read `AlplusSDK.Test.events/0`.
  Set `enabled?: false` to no-op capture without a key.

  Every public function is fail-safe. An unstarted client is a no-op.
  `start_link/1` still raises if the ingest key is missing and the SDK is
  enabled. That is a boot error, not a request error.
  """

  alias AlplusSDK.{Client, Config, Dedup, Envelope, Scope, Session, Transport}

  @type name :: Client.name()
  @type heartbeat_state :: :start | :finish | :fail

  defdelegate child_spec(opts), to: Client

  @doc """
  Starts the client. Attach this as `{AlplusSDK, []}` in the host supervisor.

  Default integrations are `:logger` and `:phoenix`. Pass
  `integrations: []` to skip them.
  """
  defdelegate start_link(opts), to: Client

  @doc """
  Captures an exception. `exception` is typically an `Exception.t()` caught
  with `rescue`; a non-exception value is stringified via `inspect/1` and
  reported with type `"Error"`, matching the JS SDK's non-Error normalization.

  Options:

    * `:stacktrace` - the `__STACKTRACE__` list (default `[]`)
    * `:cause` - the inner exception of a wrap-and-reraise (Elixir has no
      `Exception.cause/1` on 1.15–1.19). Walked into `exception.cause`.
    * `:cause_stacktrace` - `__STACKTRACE__` captured at the inner rescue
    * `:level` - `"fatal" | "error" | "warning" | "info"` (default `"error"`)
    * `:mechanism` - free-text capture source (default `"generic"`)
    * `:tags`, `:contexts`, `:context`, `:breadcrumbs`, `:fingerprint`, `:user` - scope
      overrides; `:context` is arbitrary structured data folded into
      `contexts["extra"]`. Each merges with (and wins over, per-key) the
      ambient scope for the calling process (`set_user/1` and friends).
    * `:name` - client process name (default `AlplusSDK.Client`)

  Returns the client-generated `err_` event id synchronously, always --
  even if the client isn't running, is disabled, or the enqueue fails.
  Never raises.

  Deduplicates: the same `exception` (by structural signature -- see
  `AlplusSDK.Dedup`) captured again within a short window returns the FIRST
  call's id and is not re-queued, so automatic global capture can run
  alongside a manual `capture_exception/2` call for the same error without
  double-reporting it. The dedup entry is registered only once the event is
  actually sampled in and enqueued -- deliberately AFTER the `sample_rate`
  check, not before: registering it earlier would mean a signature's first
  (sampled-out) occurrence permanently suppresses every identical capture
  for the rest of the dedup window, since nothing would ever have been
  sent for that signature to legitimately dedup against.
  """
  @spec capture_exception(Exception.t() | term(), keyword()) :: String.t()
  def capture_exception(exception, opts \\ []) do
    id = Client.generate_id()
    level = Keyword.get(opts, :level, "error")
    if level in ["error", "fatal"], do: mark_session_outcome()

    try do
      case fetch_config(opts) do
        {:ok, name, config} ->
          if Config.sampled?(config) do
            case resolve_dedup(name, exception, id) do
              {:duplicate, existing_id} ->
                Client.note_duplicate_capture(name, existing_id)
                existing_id

              {:fresh, id} ->
                item =
                  Envelope.exception_item(
                    id,
                    exception,
                    opts
                    |> merge_scope()
                    |> Keyword.put_new(:environment, config.environment)
                    |> Keyword.put_new(:release, config.release)
                    |> Keyword.put_new(:in_app_otp_apps, config.in_app_otp_apps)
                    |> Keyword.put_new(:context_lines, config.context_lines)
                  )

                case apply_before_send(config, item) do
                  nil -> :ok
                  item -> Client.enqueue(name, item)
                end

                id
            end
          else
            id
          end

        :not_running ->
          id
      end
    rescue
      _ -> id
    end
  end

  @doc """
  Captures a message (not tied to a raised exception). `level` defaults to
  `"info"`. A non-binary `message` is passed through `inspect/1` rather than
  raising `FunctionClauseError` into the caller -- the "never raises"
  guarantee applies to the argument type too, not just to transport/enqueue
  failures. Same options and guarantees as `capture_exception/2`.
  """
  @spec capture_message(term(), String.t(), keyword()) :: String.t()
  def capture_message(message, level \\ "info", opts \\ []) do
    id = Client.generate_id()
    if level in ["error", "fatal"], do: mark_session_outcome()

    try do
      case fetch_config(opts) do
        {:ok, name, config} ->
          if Config.sampled?(config) do
            item =
              Envelope.message_item(
                id,
                stringify_message(message),
                level,
                opts
                |> merge_scope()
                |> Keyword.put_new(:environment, config.environment)
                |> Keyword.put_new(:release, config.release)
              )

            case apply_before_send(config, item) do
              nil -> :ok
              item -> Client.enqueue(name, item)
            end
          end

        :not_running ->
          :ok
      end
    rescue
      _ -> :ok
    end

    id
  end

  @doc false
  @spec close_session(keyword()) :: :ok
  def close_session(opts \\ []) do
    case Session.current() do
      nil ->
        :ok

      session ->
        try do
          case fetch_config(opts) do
            {:ok, name, config} ->
              item =
                Envelope.session_item(session,
                  release: config.release,
                  environment: config.environment
                )

              Client.enqueue_session(name, item)

            :not_running ->
              :ok
          end
        rescue
          _ -> :ok
        after
          Session.clear()
        end
    end

    :ok
  end

  @doc false
  @spec mark_session_crashed() :: :ok
  def mark_session_crashed, do: Session.mark_crashed()

  @doc "Forces an immediate flush of the queue. See `AlplusSDK.Client.flush/2`."
  @spec flush(keyword()) :: :ok | :timeout
  def flush(opts \\ []) do
    name = Keyword.get(opts, :name, Client)
    timeout = Keyword.get(opts, :timeout, 5_000)

    if Process.whereis(name), do: Client.flush(name, timeout), else: :ok
  rescue
    _ -> :ok
  end

  @doc """
  Pings AL+ Monitor's `GET|POST /h/:token` for cron/job liveness
  (ARCHITECTURE.md §8): the token is the auth, `state` selects `?state=`
  (`:start` | `:finish` | `:fail`, default `:finish`; an unrecognized state
  falls back to `:finish` rather than raising -- a heartbeat call still
  records that the job ran). Recognized token -> 202 (even paused); unknown
  token -> 404 (swallowed the same as every other non-2xx below).

  A single `ping_id` (a bare UUIDv4, `AlplusSDK.Id.generate_ping_id/0`) is
  generated once per call and reused across every retry attempt as
  `?ping_id=`, matching JS's `heartbeat.ts`: Monitor's ingest dedups
  retried pings on this id, so a retried `fail`/`finish` is recorded once,
  not as two runs.

  Reuses `AlplusSDK.Transport`'s retry/backoff, but with a smaller,
  heartbeat-specific budget (`:max_attempts` 2, `:honor_retry_after`
  `false`) instead of Observe ingest's default 3 attempts honoring a
  `Retry-After` up to 30s: this function runs synchronously on the
  caller's own thread (correct for a cron/script that must report before
  it exits), so it blocks the caller briefly (worst case: one ~500ms-1.5s
  jittered backoff) rather than risking a long server-supplied delay.

  The base URL resolves the same way `AlplusSDK.Config` does -- a running
  named `AlplusSDK.Client`'s own `start_link/1` `:base_url` first (so a
  self-hosted ingest endpoint configured only via `start_link` opts, not
  `Application.get_env/3` or `ALPLUS_ENDPOINT`, is still honored), then
  `Application.get_env(:alplus_sdk, :config, base_url: ...)`, then
  `ALPLUS_ENDPOINT`, then the default -- but a running `AlplusSDK.Client`
  is not required (a cron job that only reports liveness, with no error
  reporting configured, is a normal use of this function).

  `transport_opts` forwards additional options to the HTTP adapter
  (namely `:sleep_fun`, for this package's own tests); not part of the
  documented public contract.

  Fail-safe and off the request path: always returns `:ok`, never raises,
  even if `token` isn't a binary.
  """
  @spec heartbeat(String.t(), heartbeat_state(), keyword()) :: :ok
  def heartbeat(token, state \\ :finish, transport_opts \\ []) do
    try do
      ping_id = AlplusSDK.Id.generate_ping_id()

      url =
        heartbeat_base_url() <>
          "/h/" <>
          URI.encode(token, &URI.char_unreserved?/1) <>
          "?state=" <> heartbeat_state_param(state) <> "&ping_id=" <> ping_id

      Transport.request(
        :post,
        url,
        Keyword.merge(
          [
            receive_timeout: 5_000,
            debug_label: "heartbeat",
            max_attempts: 2,
            honor_retry_after: false
          ],
          transport_opts
        )
      )
    rescue
      _ -> :ok
    end

    :ok
  end

  @doc """
  Sets the ambient user for this process. Call after `AlplusSDK.Plug`.

  `user` is a map with `:id` or `"id"` and optional email. `nil` clears it.
  Never raises.
  """
  @spec set_user(map() | nil) :: :ok
  def set_user(user) do
    Scope.set_user(user)
  end

  @doc "Sets one ambient tag on this process. Never raises."
  @spec set_tag(term(), term()) :: :ok
  def set_tag(key, value) do
    Scope.set_tag(key, value)
  end

  @doc "Sets one named ambient context on this process. Never raises."
  @spec set_context(term(), map()) :: :ok
  def set_context(name, data) do
    Scope.set_context(name, data)
  end

  @doc """
  Appends one breadcrumb to this process's ambient trail.

  Accepts a map with `:message` / `:category` / `:level` / `:data`.
  Never raises.
  """
  @spec add_breadcrumb(map()) :: :ok
  def add_breadcrumb(breadcrumb) do
    Scope.add_breadcrumb(breadcrumb)
  end

  defp heartbeat_state_param(state) when state in [:start, :finish, :fail],
    do: Atom.to_string(state)

  defp heartbeat_state_param(_other), do: "finish"

  defp heartbeat_base_url do
    case fetch_config([]) do
      {:ok, _name, config} -> config.base_url
      :not_running -> heartbeat_base_url_fallback()
    end
    |> String.trim_trailing("/")
  end

  defp heartbeat_base_url_fallback do
    app_env = Application.get_env(:alplus_sdk, :config, [])

    Keyword.get(app_env, :base_url) || System.get_env("ALPLUS_ENDPOINT") ||
      "https://ingest.alplus.dev"
  end

  defp stringify_message(message) when is_binary(message), do: message
  defp stringify_message(message), do: inspect(message)

  defp fetch_config(opts) do
    name = Keyword.get(opts, :name, Client)

    if Process.whereis(name) do
      {:ok, name, Client.config(name)}
    else
      :not_running
    end
  catch
    :exit, _ -> :not_running
  end

  # Any `"error"`/`"fatal"`-level capture during the current session marks
  # it (at least) `:errored` -- a no-op if the session is already
  # `:crashed` (see `AlplusSDK.Session`'s severity ordering) or if no
  # session was started (e.g. a background job, not a request).
  defp mark_session_outcome, do: Session.mark_errored()

  defp resolve_dedup(name, exception, fresh_id) do
    Client.resolve_dedup(name, Dedup.signature(exception), fresh_id)
  end

  defp apply_before_send(%{before_send: nil}, item), do: item

  defp apply_before_send(%{before_send: fun}, item) when is_function(fun, 1) do
    case fun.(item) do
      nil -> nil
      false -> nil
      updated when is_map(updated) -> updated
      _ -> item
    end
  rescue
    _ -> item
  end

  # Merges the calling process's ambient `AlplusSDK.Scope` with per-call
  # `opts` overrides, mirroring `mergeScope` in
  # `packages/sdk/src/core/observe/scope.ts`: an override wins field-by-field
  # over the ambient value (an explicit `user: nil` clears the ambient user
  # for this one capture), `tags`/`contexts` shallow-merge with the
  # override's keys taking precedence on collision, and breadcrumbs
  # concatenate (ambient trail first, then any one-off breadcrumbs passed
  # for this call).
  defp merge_scope(opts) do
    ambient = Scope.current()

    user =
      case Keyword.fetch(opts, :user) do
        {:ok, user} -> user
        :error -> ambient.user
      end

    tags = Map.merge(ambient.tags, Keyword.get(opts, :tags) || %{})
    contexts = Map.merge(ambient.contexts, Keyword.get(opts, :contexts) || %{})
    breadcrumbs = ambient.breadcrumbs ++ (Keyword.get(opts, :breadcrumbs) || [])

    opts
    |> Keyword.put(:user, user)
    |> Keyword.put(:tags, if(map_size(tags) == 0, do: nil, else: tags))
    |> Keyword.put(:contexts, if(map_size(contexts) == 0, do: nil, else: contexts))
    |> Keyword.put(:breadcrumbs, if(breadcrumbs == [], do: nil, else: breadcrumbs))
  end
end
