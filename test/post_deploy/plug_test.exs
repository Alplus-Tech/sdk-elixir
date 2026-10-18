defmodule PostDeploy.PlugTest do
  use ExUnit.Case, async: true

  alias PostDeploy.{Client, Scope}

  setup do
    Scope.clear()
    :ok
  end

  test "call/2 clears any leftover ambient scope" do
    Scope.set_user(%{id: "stale"})
    Scope.set_tag("stale", "yes")

    conn = %{assigns: %{}}
    result = PostDeploy.Plug.call(conn, PostDeploy.Plug.init([]))

    assert result == conn
    assert Scope.current() == %Scope{}
  end

  test "call/2 is a no-op passthrough on something without :assigns, never raising" do
    assert :not_a_conn == PostDeploy.Plug.call(:not_a_conn, [])
  end

  test "init/1 returns opts unchanged" do
    assert [foo: :bar] == PostDeploy.Plug.init(foo: :bar)
  end

  test "call/2 attaches request context from a real conn, with allowlisted headers only" do
    conn =
      Plug.Test.conn(:post, "/orders?coupon=SAVE10")
      |> Plug.Conn.put_req_header("user-agent", "TestBrowser/1.0")
      |> Plug.Conn.put_req_header("cookie", "session=shh")
      |> Plug.Conn.put_req_header("authorization", "Bearer shh")

    PostDeploy.Plug.call(conn, PostDeploy.Plug.init([]))

    assert %{
             "method" => "POST",
             "path" => "/orders",
             "host" => "www.example.com",
             "headers" => %{"user-agent" => "TestBrowser/1.0"}
           } = Scope.current().contexts["request"]

    refute Map.has_key?(Scope.current().contexts["request"]["headers"], "cookie")
    refute Map.has_key?(Scope.current().contexts["request"]["headers"], "authorization")
  end

  test "call/2 attaches no request context for a bare assigns map" do
    PostDeploy.Plug.call(%{assigns: %{}}, PostDeploy.Plug.init([]))
    assert Scope.current().contexts == %{}
  end

  test "a request through the plug sends nothing to ingest when nothing is captured" do
    bypass = Bypass.open()
    name = :"plug_client_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Client,
       name: name,
       key: "alp_p_test_key_123",
       base_url: "http://localhost:#{bypass.port}",
       flush_interval_ms: 0,
       integrations: []}
    )

    conn =
      Plug.Test.conn(:get, "/")
      |> PostDeploy.Plug.call(name: name)
      |> Plug.Conn.send_resp(200, "ok")

    assert conn.status == 200
    assert :ok == Client.flush(name, 1_000)
  end
end
