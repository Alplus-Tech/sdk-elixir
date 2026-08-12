defmodule AlplusSDK do
  @moduledoc """
  Elixir client for AL+ Observe error reporting (`POST /e/errors`).

  ## Setup

  Add a child to your application's supervision tree:

      children = [
        {AlplusSDK, key: System.fetch_env!("ALPLUS_INGEST_KEY"), environment: "production", release: "..."},
        ...
      ]

  Or configure via `config.exs` and start with just `{AlplusSDK, []}`:

      config :alplus_sdk, config: [
        key: {:system, "ALPLUS_INGEST_KEY"},
        environment: "production"
      ]

  In `test`/`dev`, set `enabled?: false` (or `config :alplus_sdk, config: [enabled?: false]`)
  to run in no-op mode: `capture_*` still returns an event id but never enqueues or
  hits the network.

  ## Usage

      try do
        risky()
      rescue
        exception -> AlplusSDK.capture_exception(exception, stacktrace: __STACKTRACE__)
      end

      AlplusSDK.capture_message("something worth a look", "warning")

  Every public function here is fail-safe: it never raises into the caller,
  even if the SDK was never started (an unstarted/absent client is a no-op).
  """

  alias AlplusSDK.{Client, Envelope}

  @type name :: Client.name()

  defdelegate child_spec(opts), to: Client

  @doc "See `AlplusSDK.Client.start_link/1`."
  defdelegate start_link(opts), to: Client

  @doc """
  Captures an exception. `exception` is typically an `Exception.t()` caught
  with `rescue`; a non-exception value is stringified via `inspect/1` and
  reported with type `"Error"`, matching the JS SDK's non-Error normalization.

  Options:

    * `:stacktrace` - the `__STACKTRACE__` list (default `[]`)
    * `:level` - `"fatal" | "error" | "warning" | "info"` (default `"error"`)
    * `:mechanism` - free-text capture source (default `"generic"`)
    * `:tags`, `:contexts`, `:breadcrumbs`, `:fingerprint`, `:user` - scope overrides
    * `:name` - client process name (default `AlplusSDK.Client`)

  Returns the client-generated `err_` event id synchronously, always --
  even if the client isn't running, is disabled, or the enqueue fails.
  Never raises.
  """
  @spec capture_exception(Exception.t() | term(), keyword()) :: String.t()
  def capture_exception(exception, opts \\ []) do
    id = Client.generate_id()

    try do
      case fetch_config(opts) do
        {:ok, name, config} ->
          item =
            Envelope.exception_item(
              id,
              exception,
              opts
              |> Keyword.put_new(:environment, config.environment)
              |> Keyword.put_new(:release, config.release)
              |> Keyword.put_new(:in_app_otp_apps, config.in_app_otp_apps)
            )

          Client.enqueue(name, item)

        :not_running ->
          :ok
      end
    rescue
      _ -> :ok
    end

    id
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

    try do
      case fetch_config(opts) do
        {:ok, name, config} ->
          item =
            Envelope.message_item(
              id,
              stringify_message(message),
              level,
              opts
              |> Keyword.put_new(:environment, config.environment)
              |> Keyword.put_new(:release, config.release)
            )

          Client.enqueue(name, item)

        :not_running ->
          :ok
      end
    rescue
      _ -> :ok
    end

    id
  end

  @doc "Forces an immediate flush of the queue. See `AlplusSDK.Client.flush/2`."
  @spec flush(keyword()) :: :ok | :timeout
  def flush(opts \\ []) do
    name = Keyword.get(opts, :name, Client)
    timeout = Keyword.get(opts, :timeout, 5_000)

    if Process.whereis(name), do: Client.flush(name, timeout), else: :ok
  rescue
    _ -> :ok
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
end
