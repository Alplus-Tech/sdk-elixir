defmodule AlplusSDK.Telemetry do
  @moduledoc false

  alias AlplusSDK.Client

  @doc """
  Attaches the handler. `opts` accepts `:name` (client process name,
  default `AlplusSDK.Client`) and `:handler_id` (default
  `:alplus_sdk_phoenix_errors`, for `detach/1`). Safe to call more than
  once: re-attaching with the same `:handler_id` first detaches the old one.
  """
  @spec attach_phoenix(keyword()) :: :ok
  def attach_phoenix(opts \\ []) do
    handler_id = Keyword.get(opts, :handler_id, :alplus_sdk_phoenix_errors)
    name = Keyword.get(opts, :name, Client)

    :telemetry.detach(handler_id)

    :telemetry.attach(
      handler_id,
      [:phoenix, :error_rendered],
      &__MODULE__.handle_event/4,
      %{name: name}
    )
  end

  @spec detach(atom()) :: :ok
  def detach(handler_id \\ :alplus_sdk_phoenix_errors), do: :telemetry.detach(handler_id)

  @doc false
  def handle_event([:phoenix, :error_rendered], _measurements, metadata, %{name: name}) do
    if capture?(metadata) do
      # Runs synchronously, in the request process, inside
      # `Phoenix.Endpoint.RenderErrors`'s rescue -- this IS the
      # unhandled-exception signal for the request-scoped session (issue
      # #12, ARCHITECTURE.md decision #2: crashed = unhandled/fatal only).
      # Marked BEFORE the `capture_exception` call below: that call would
      # otherwise mark the session merely `:errored` (any `"error"`-level
      # capture does), and `:crashed` must win regardless of call order --
      # `AlplusSDK.Session`'s severity ordering makes this safe either way.
      AlplusSDK.mark_session_crashed()

      AlplusSDK.capture_exception(
        normalize(metadata),
        stacktrace: Map.get(metadata, :stacktrace, []),
        mechanism: "phoenix.error_rendered",
        name: name
      )
    end

    :ok
  end

  defp capture?(%{status: status}) when is_integer(status), do: status >= 500
  defp capture?(_), do: true

  defp normalize(%{reason: %_{__exception__: true} = exception}), do: exception

  defp normalize(%{kind: kind, reason: reason}),
    do: RuntimeError.exception("#{inspect(kind)}: #{inspect(reason)}")

  defp normalize(metadata), do: RuntimeError.exception(inspect(metadata))
end
