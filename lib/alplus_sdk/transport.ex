defmodule AlplusSDK.Transport do
  @moduledoc """
  Wraps `Req` for the one request this SDK makes (`POST /e/errors`), behind
  a project-owned module so `AlplusSDK.Client` never calls `Req` directly.
  Every outcome (2xx, 4xx/5xx, timeout, connection error) is swallowed here:
  Observe ingest is best-effort telemetry, never allowed to raise into the
  host application that depends on this SDK.
  """

  require Logger

  alias AlplusSDK.Config

  @doc "POSTs an already-encoded envelope body to `config.base_url <> \"/e/errors\"`. Always returns `:ok`; never raises."
  @spec post(Config.t(), String.t()) :: :ok
  def post(%Config{} = config, body) when is_binary(body) do
    url = String.trim_trailing(config.base_url, "/") <> "/e/errors"

    Req.post(url,
      body: body,
      headers: [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{config.key}"}
      ],
      receive_timeout: config.receive_timeout,
      retry: false
    )
    |> handle_response(config)

    :ok
  rescue
    error ->
      if config.debug do
        Logger.debug(
          "alplus_sdk: transport error posting to Observe: #{Exception.format(:error, error, __STACKTRACE__)}"
        )
      end

      :ok
  end

  defp handle_response({:ok, %Req.Response{status: status}}, _config) when status in 200..299 do
    :ok
  end

  defp handle_response({:ok, %Req.Response{status: status}}, config) do
    if config.debug, do: Logger.debug("alplus_sdk: Observe ingest responded #{status}")
    :ok
  end

  defp handle_response({:error, reason}, config) do
    if config.debug,
      do: Logger.debug("alplus_sdk: Observe ingest request failed: #{inspect(reason)}")

    :ok
  end
end
