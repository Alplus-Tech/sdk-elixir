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

  # Sub-error levels (issue #47): the line becomes a `log` breadcrumb on
  # THIS process's scope (handlers run synchronously in the logging
  # process) and is offered to any exception item this process captured
  # that is still inside its post-error log window. Error-and-above lines
  # never reach this clause — they become events above, and an event must
  # not also carry itself as a breadcrumb.
  def log(%{level: level} = log_event, config)
      when level in [:debug, :info, :notice, :warning] do
    handler_config = Map.get(config, :config) || %{}
    name = Map.get(handler_config, :name) || Client

    # The SDK-prefix check runs BEFORE anything touches `Client`: the
    # client's own `Logger.debug("alplus_sdk: ...")` lines must not
    # re-enter it (and are the SDK talking to itself besides). Everything
    # here is a pdict write plus one cast — never a call, so a busy client
    # can never block the host's logging.
    with false <- Map.get(handler_config, :logger_breadcrumbs) == false,
         message when is_binary(message) <- extract_message(log_event),
         false <- String.starts_with?(message, "alplus_sdk") do
      crumb = %{
        category: "log",
        message: message,
        level: breadcrumb_level(level),
        ts: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      AlplusSDK.Scope.add_breadcrumb(crumb)
      Client.notify_log_breadcrumb(name, crumb)
    end

    :ok
  rescue
    _ -> :ok
  end

  def log(_log_event, _config), do: :ok

  defp extract_message(%{msg: {:string, message}}) when is_binary(message), do: message

  defp extract_message(%{msg: {:string, message}}) when is_list(message),
    do: IO.iodata_to_binary(message)

  defp extract_message(%{msg: {format, args}}) when is_list(args), do: safe_format(format, args)
  defp extract_message(_log_event), do: nil

  defp breadcrumb_level(:debug), do: "debug"
  defp breadcrumb_level(:info), do: "info"
  defp breadcrumb_level(:notice), do: "info"
  defp breadcrumb_level(:warning), do: "warning"

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
