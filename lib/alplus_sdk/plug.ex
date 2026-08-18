defmodule AlplusSDK.Plug do
  @moduledoc """
  Resets ambient scope and opens a crash-free session at the start of
  every request. Add it first in the endpoint, before any plug that
  calls `AlplusSDK.set_user/1`:

      plug AlplusSDK.Plug

  `{AlplusSDK, []}` already attaches the Phoenix error handler. This plug
  still has to sit in the pipeline so request order is visible.

  Accepts `:name` when the host runs more than one named client.

  The plug opens a session and closes it when the response is ready.
  An unhandled 500 marks the session crashed via the Phoenix handler
  attached at `start_link/1`.

  Duck-typed on `conn.assigns`. This package does not depend on `:plug`.
  """

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, opts) do
    case conn do
      %{assigns: _} ->
        AlplusSDK.Scope.clear()
        attach_request_context(conn)
        AlplusSDK.Session.start()
        register_close_session(conn, Keyword.get(opts, :name, AlplusSDK.Client))

      _ ->
        conn
    end
  rescue
    _ -> conn
  end

  # Attaches `contexts.request` (method, host, path, allowlisted headers)
  # to the fresh scope so every capture during this request carries it.
  # Query string and body params are deliberately absent: at this point in
  # the pipeline `conn.params` is unfetched, and a raw query string cannot
  # be key-scrubbed. A host wanting params attaches them itself, after its
  # own parsing and filtering, via `AlplusSDK.Scope.set_context/2`.
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

    if map_size(context) > 0, do: AlplusSDK.Scope.set_context("request", context)
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

  # `Plug.Conn.register_before_send/2` is called via `apply/3`, never a
  # direct qualified call: `alplus_sdk` has no compile-time dependency on
  # `:plug` (see moduledoc), and a direct `Plug.Conn.register_before_send`
  # call -- unlike this dynamic one -- would require the module to exist at
  # COMPILE time.
  #
  # Deliberately does NOT gate on `function_exported?(Plug.Conn, ...)`
  # first: that check reports whether the module's export table is already
  # LOADED into this node's code server, which a struct literal built
  # elsewhere (e.g. `Plug.Test.conn/2`) does not guarantee -- it returned a
  # false negative here even with `:plug` present and the struct already
  # built, silently skipping registration. Calling `apply/3` directly goes
  # through the normal dynamic-call path, which loads the module on demand
  # exactly like a qualified `Plug.Conn.register_before_send/2` call would;
  # `rescue` below is the actual (and sufficient) fallback for a host with
  # no `:plug` at all, converting the resulting `UndefinedFunctionError`
  # into a no-op.
  defp register_close_session(conn, client_name) do
    apply(Plug.Conn, :register_before_send, [
      conn,
      fn conn ->
        AlplusSDK.close_session(name: client_name)
        conn
      end
    ])
  rescue
    _ -> conn
  end
end
