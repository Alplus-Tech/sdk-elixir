defmodule AlplusSDK.LoggerHandler do
  @moduledoc """
  An OTP `:logger` handler (Erlang/OTP kernel logger, not a Logger
  *backend*) that auto-captures crash reports as Observe exception events --
  the "unhandled exceptions captured automatically" story, without wrapping
  every call site.

  `:proc_lib`/OTP crash reports (a `GenServer`, `Task`, or plain process
  crashing) are logged by the kernel logger with `meta[:crash_reason]` set
  to `{reason, stacktrace}` -- this is the same metadata key
  `sentry_elixir`'s equivalent handler and Elixir's own `Logger.Translator`
  rely on. Every other `:error`-and-above report (one without a crash
  reason, e.g. a plain `Logger.error("...")` call) is captured as a
  message, so a deliberate error log still reaches Observe.

  ## Setup

      :logger.add_handler(:alplus_sdk, AlplusSDK.LoggerHandler, %{
        config: %{name: AlplusSDK.Client}
      })

  Add this once, typically in your `Application.start/2`, after starting
  the `AlplusSDK.Client` child (order does not matter: capture calls are
  no-ops until the client is running).
  """

  alias AlplusSDK.Client

  @doc "`:logger` handler callback. Never raises: a malformed log event is swallowed, not propagated back into the logger."
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, meta: meta} = log_event, config)
      when level in [:emergency, :alert, :critical, :error] do
    name = get_in(config, [:config, :name]) || Client

    case Map.get(meta, :crash_reason) do
      {reason, stacktrace} when is_list(stacktrace) ->
        AlplusSDK.capture_exception(normalize_crash_reason(reason),
          stacktrace: stacktrace,
          mechanism: "logger",
          name: name,
          level: "error"
        )

      _ ->
        capture_plain_report(log_event, name)
    end

    :ok
  rescue
    _ -> :ok
  end

  def log(_log_event, _config), do: :ok

  defp capture_plain_report(%{msg: {:string, message}}, name) when is_binary(message) do
    AlplusSDK.capture_message(message, "error", mechanism: "logger", name: name)
  end

  defp capture_plain_report(%{msg: {:string, message}}, name) when is_list(message) do
    AlplusSDK.capture_message(IO.iodata_to_binary(message), "error",
      mechanism: "logger",
      name: name
    )
  end

  defp capture_plain_report(%{msg: {format, args}}, name) when is_list(args) do
    AlplusSDK.capture_message(safe_format(format, args), "error", mechanism: "logger", name: name)
  end

  defp capture_plain_report(_log_event, _name), do: :ok

  defp safe_format(format, args) do
    :io_lib.format(format, args) |> IO.iodata_to_binary()
  rescue
    _ -> inspect({format, args})
  end

  defp normalize_crash_reason(%_{__exception__: true} = exception), do: exception
  defp normalize_crash_reason(reason), do: RuntimeError.exception(inspect(reason))
end
