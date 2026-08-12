defmodule AlplusSDK.Plug do
  @moduledoc """
  Resets `AlplusSDK.Scope` and opens a fresh `AlplusSDK.Session` (issue
  #12) at the start of every request. Add it first, before any plug that
  calls `AlplusSDK.Scope.set_user/1` etc, so a fresh request never inherits
  scope or session state from a previous one:

      plug AlplusSDK.Plug
      plug MyAppWeb.AlplusScopePlug

  Accepts one option, `:name` -- the `AlplusSDK.Client` process name
  (default `AlplusSDK.Client`, same default as every other `AlplusSDK`
  function), forwarded to `AlplusSDK.close_session/1`. Only needed for a
  host running more than one named client.

  Cowboy and Bandit already give each request its own Erlang process (so
  the ambient scope/session in the process dictionary cannot leak between
  requests under normal operation) -- this plug is a defensive reset for
  the one case that would defeat that: a pooled/reused process (e.g. a
  custom adapter, or a future change to the web server) carrying over
  stale state from whatever request ran in it last.

  ## Session lifecycle (issue #12)

  This plug opens the session and, via `Plug.Conn.register_before_send/2`,
  closes it (`AlplusSDK.close_session/1`) once the response is ready --
  `:healthy` unless something during the request marked it `:errored`
  (`AlplusSDK.capture_exception/2`/`capture_message/3` at level
  `"error"`/`"fatal"`) or `:crashed`.

  A plain `plug` entry cannot itself wrap the plugs that run AFTER it
  (Plug/Phoenix compiles a pipeline into one sequential function, not
  nested calls -- there is no `call/2` frame here left on the stack by the
  time a downstream plug/controller raises), so this module cannot
  `rescue` an unhandled exception directly the way
  `sdks/ruby/lib/alplus/rack_middleware.rb`'s `Rack` middleware can. The
  crash signal instead comes from `AlplusSDK.Telemetry.attach_phoenix/1`,
  which observes Phoenix's own `[:phoenix, :error_rendered]` event
  (fired, in-process, for exactly the unhandled-exception case) and calls
  `AlplusSDK.mark_session_crashed/0` before this plug's `before_send`
  callback runs. A host with no Phoenix (bare Plug) that wants `:crashed`
  detection needs its own rescue calling `AlplusSDK.mark_session_crashed/0`
  -- see that function's docs.

  Duck-typed on `conn.assigns` (any struct/map with an `:assigns` key)
  rather than `%Plug.Conn{}` directly, so `alplus_sdk` itself never depends
  on the `:plug` library at compile time -- most hosts using this module
  already depend on Phoenix/Plug, but the SDK core does not require it.
  Attempting `register_before_send/2` on a bare `%{assigns: %{}}` test
  double (no such callback registry) is a swallowed `UndefinedFunctionError`
  -- the session is simply left open in that case, closed only by the next
  `AlplusSDK.Session.start/0` reset.
  """

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, opts) do
    case conn do
      %{assigns: _} ->
        AlplusSDK.Scope.clear()
        AlplusSDK.Session.start()
        register_close_session(conn, Keyword.get(opts, :name, AlplusSDK.Client))

      _ ->
        conn
    end
  rescue
    _ -> conn
  end

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
