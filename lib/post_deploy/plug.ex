defmodule PostDeploy.Plug do
  @moduledoc """
  Resets ambient scope and attaches request context at the start of every
  request. Add it first in the endpoint, before any plug that calls
  `PostDeploy.set_user/1`:

      plug PostDeploy.Plug

  `{PostDeploy, []}` already attaches the Phoenix error handler. This plug
  still has to sit in the pipeline so request order is visible.

  Duck-typed on `conn.assigns`. This package does not depend on `:plug`.
  """

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case conn do
      %{assigns: _} ->
        PostDeploy.Scope.clear()
        attach_request_context(conn)
        conn

      _ ->
        conn
    end
  end

  # Attaches `contexts.request` (method, host, path, allowlisted headers)
  # to the fresh scope so every capture during this request carries it.
  # Query string and body params are deliberately absent: at this point in
  # the pipeline `conn.params` is unfetched, and a raw query string cannot
  # be key-scrubbed. A host wanting params attaches them itself, after its
  # own parsing and filtering, via `PostDeploy.Scope.set_context/2`.
  # Duck-typed like the rest of this module; anything short of a real
  # `Plug.Conn` shape is a swallowed no-op.
  defp attach_request_context(conn) do
    context =
      %{
        "method" => Map.get(conn, :method),
        "host" => Map.get(conn, :host),
        "path" => Map.get(conn, :request_path),
        "headers" => request_headers(conn)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(context) > 0, do: PostDeploy.Scope.set_context("request", context)
  rescue
    _ -> :ok
  end

  @request_header_allowlist ~w(user-agent referer accept content-type x-request-id)

  defp request_headers(%{req_headers: headers}) when is_list(headers) do
    case Map.new(Enum.filter(headers, fn {name, _} -> name in @request_header_allowlist end)) do
      empty when map_size(empty) == 0 -> nil
      picked -> picked
    end
  end

  defp request_headers(_conn), do: nil
end
