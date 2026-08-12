defmodule AlplusSDK.Session do
  @moduledoc """
  Request-scoped session-health tracker for AL+ Observe's crash-free
  sessions metric (issue #12). One request = one session, Sentry
  "request-mode" style: `AlplusSDK.Plug` opens it, this module accumulates
  its outcome as the request runs, and `AlplusSDK.Plug` closes it when the
  response is sent.

  State lives in the process dictionary, exactly like `AlplusSDK.Scope`, for
  the same reason: Cowboy/Bandit give each request its own process, so this
  is the correct (and only) place request-local mutable state belongs
  without threading an accumulator through every call site.

  Three outcomes, in ascending severity, matching ARCHITECTURE.md's
  decision #2 (Sentry-aligned):

    * `:healthy` -- the request completed with no captured error.
    * `:errored` -- the request captured a handled error (any
      `AlplusSDK.capture_exception/2`/`capture_message/3` at level
      `"error"`/`"fatal"`).
    * `:crashed` -- the request's response was rendered from an UNHANDLED
      exception. Only this state counts against crash-free sessions.

  Severity only ever increases within one request: `mark_errored/0` is a
  no-op once `mark_crashed/0` has run, so a handled-error capture made
  while unwinding a crash (e.g. `AlplusSDK.Telemetry`'s own
  `capture_exception` call for the crash itself) can never downgrade the
  outcome back to `:errored`.
  """

  @pdict_key :__alplus_sdk_session__

  @type status :: :healthy | :errored | :crashed

  @type t :: %{
          id: String.t(),
          status: status(),
          started_at: DateTime.t()
        }

  @doc "Starts a fresh session for the current process, discarding any previous one."
  @spec start() :: t()
  def start do
    session = %{
      id: AlplusSDK.Id.generate_session_id(),
      status: :healthy,
      started_at: DateTime.utc_now()
    }

    Process.put(@pdict_key, session)
    session
  rescue
    _ ->
      %{id: AlplusSDK.Id.generate_session_id(), status: :healthy, started_at: DateTime.utc_now()}
  end

  @doc "The current process's session, or `nil` if none was started."
  @spec current() :: t() | nil
  def current, do: Process.get(@pdict_key)

  @doc "Marks the current session `:errored`, unless it is already `:crashed`."
  @spec mark_errored() :: :ok
  def mark_errored, do: bump(:errored)

  @doc "Marks the current session `:crashed`. Terminal: never downgraded within the same request."
  @spec mark_crashed() :: :ok
  def mark_crashed, do: bump(:crashed)

  @doc "Clears the current process's session. Called by `AlplusSDK.Plug` at the start of every request."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  defp bump(new_status) do
    case current() do
      nil ->
        :ok

      session ->
        if severity(new_status) > severity(session.status) do
          Process.put(@pdict_key, %{session | status: new_status})
        end

        :ok
    end
  rescue
    _ -> :ok
  end

  defp severity(:healthy), do: 0
  defp severity(:errored), do: 1
  defp severity(:crashed), do: 2
end
