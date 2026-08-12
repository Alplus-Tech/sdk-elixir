defmodule AlplusSDK.PlugTest do
  use ExUnit.Case, async: true

  alias AlplusSDK.{Client, Scope, Session}

  setup do
    Scope.clear()
    Session.clear()
    :ok
  end

  test "call/2 clears any leftover ambient scope" do
    Scope.set_user(%{id: "stale"})
    Scope.set_tag("stale", "yes")

    conn = %{assigns: %{}}
    result = AlplusSDK.Plug.call(conn, AlplusSDK.Plug.init([]))

    assert result == conn
    assert Scope.current() == %Scope{}
  end

  test "call/2 is a no-op passthrough on something without :assigns, never raising" do
    assert :not_a_conn == AlplusSDK.Plug.call(:not_a_conn, [])
  end

  test "init/1 returns opts unchanged" do
    assert [foo: :bar] == AlplusSDK.Plug.init(foo: :bar)
  end

  test "call/2 opens a fresh healthy session (issue #12)" do
    conn = %{assigns: %{}}
    AlplusSDK.Plug.call(conn, AlplusSDK.Plug.init([]))

    assert %{status: :healthy, id: "ses_" <> _} = Session.current()
  end

  describe "session lifecycle over a real %Plug.Conn{} (issue #12)" do
    setup do
      bypass = Bypass.open()
      name = :"plug_session_client_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Client,
         name: name,
         key: "alp_p_test_key_123",
         base_url: "http://localhost:#{bypass.port}",
         flush_interval_ms: 0,
         batch_max_items: 1_000}
      )

      {:ok, bypass: bypass, name: name}
    end

    test "send_resp closes the session as healthy when nothing was captured", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/sessions", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      conn =
        Plug.Test.conn(:get, "/")
        |> AlplusSDK.Plug.call(name: name)
        |> Plug.Conn.send_resp(200, "ok")

      assert conn.status == 200
      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000

      %{"items" => [item]} = Jason.decode!(raw_body)
      assert item["status"] == "healthy"
      assert String.starts_with?(item["id"], "ses_")
    end

    test "a handled capture_exception/2 during the request closes the session as errored", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/sessions", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      Bypass.stub(bypass, "POST", "/e/errors", fn conn -> Plug.Conn.resp(conn, 202, "{}") end)

      conn = Plug.Test.conn(:get, "/") |> AlplusSDK.Plug.call(name: name)
      AlplusSDK.capture_exception(%RuntimeError{message: "handled"}, name: name)
      Plug.Conn.send_resp(conn, 200, "ok")

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000

      %{"items" => [item]} = Jason.decode!(raw_body)
      assert item["status"] == "errored"
    end

    test "AlplusSDK.mark_session_crashed/0 during the request closes the session as crashed", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/sessions", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      Bypass.stub(bypass, "POST", "/e/errors", fn conn -> Plug.Conn.resp(conn, 202, "{}") end)

      conn = Plug.Test.conn(:get, "/") |> AlplusSDK.Plug.call(name: name)
      AlplusSDK.mark_session_crashed()
      AlplusSDK.capture_exception(%RuntimeError{message: "unhandled"}, name: name)
      Plug.Conn.send_resp(conn, 500, "boom")

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000

      %{"items" => [item]} = Jason.decode!(raw_body)
      assert item["status"] == "crashed"
    end
  end
end
