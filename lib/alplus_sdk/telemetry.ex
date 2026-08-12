defmodule AlplusSDK.Telemetry do
  @moduledoc """
  Attaches a `:telemetry` handler for Phoenix's documented
  `[:phoenix, :error_rendered]` event
  (`deps/phoenix/lib/phoenix/endpoint/render_errors.ex`), so a request that
  reaches `Phoenix.Endpoint.RenderErrors` is auto-captured without wrapping
  every controller/router call site.

  `[:phoenix, :error_rendered]` metadata carries `%{kind:, reason:, stacktrace:, status:}`
  for every rendered error, including expected 404s -- this handler only
  captures `status >= 500` (or a `kind`/`reason` combination Phoenix itself
  wouldn't map to a 4xx), matching what a developer means by "unhandled
  exception".
  """

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
      AlplusSDK.capture_exception(
        normalize(metadata),
        stacktrace: Map.get(metadata, :stacktrace, []),
        mechanism: "phoenix.error_rendered",
        name: name
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp capture?(%{status: status}) when is_integer(status), do: status >= 500
  defp capture?(_), do: true

  defp normalize(%{reason: %_{__exception__: true} = exception}), do: exception

  defp normalize(%{kind: kind, reason: reason}),
    do: RuntimeError.exception("#{inspect(kind)}: #{inspect(reason)}")

  defp normalize(metadata), do: RuntimeError.exception(inspect(metadata))
end
