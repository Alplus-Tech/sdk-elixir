defmodule AlplusSDK.HeartbeatTest do
  @moduledoc """
  `AlplusSDK.heartbeat/3` resolves its base URL through a running named
  `AlplusSDK.Client`, then `Application.get_env(:alplus_sdk, :config, ...)`
  (the same source `AlplusSDK.Config` reads), so this file runs
  `async: false` and restores that env after each test.

  Every test passes `sleep_fun: fn _ -> :ok end` via `heartbeat/3`'s third
  (internal, test-only) `transport_opts` argument so retry tests never wait
  on real wall-clock time.
  """

  use ExUnit.Case, async: false

  alias AlplusSDK.Client

  setup do
    previous = Application.get_env(:alplus_sdk, :config)
    on_exit(fn -> Application.put_env(:alplus_sdk, :config, previous || []) end)

    bypass = Bypass.open()
    Application.put_env(:alplus_sdk, :config, base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass}
  end

  test "defaults to state=finish and hits GET|POST /h/:token with a ping_id", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/h/hb_test_token", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:request, conn.query_params})
      Plug.Conn.resp(conn, 202, "{}")
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token")

    assert_receive {:request, params}, 1_000
    assert params["state"] == "finish"
    assert is_binary(params["ping_id"])
    assert params["ping_id"] =~ ~r/^[0-9a-f-]{36}$/
  end

  test "an explicit :start state is sent as ?state=start", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/h/hb_test_token", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:request, conn.query_params})
      Plug.Conn.resp(conn, 202, "{}")
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token", :start)
    assert_receive {:request, %{"state" => "start"}}, 1_000
  end

  test "an explicit :fail state is sent as ?state=fail", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/h/hb_test_token", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:request, conn.query_params})
      Plug.Conn.resp(conn, 202, "{}")
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token", :fail)
    assert_receive {:request, %{"state" => "fail"}}, 1_000
  end

  test "an unrecognized state falls back to finish instead of raising", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/h/hb_test_token", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:request, conn.query_params})
      Plug.Conn.resp(conn, 202, "{}")
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token", :bogus)
    assert_receive {:request, %{"state" => "finish"}}, 1_000
  end

  test "the same ping_id is reused across every retry attempt", %{bypass: bypass} do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    Bypass.expect(bypass, "POST", "/h/hb_test_token", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:attempt, count, conn.query_params["ping_id"]})

      if count == 1 do
        Plug.Conn.resp(conn, 503, "unavailable")
      else
        Plug.Conn.resp(conn, 202, "{}")
      end
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token", :finish, no_sleep())

    assert_receive {:attempt, 1, ping_id_1}, 1_000
    assert_receive {:attempt, 2, ping_id_2}, 1_000
    assert ping_id_1 == ping_id_2
  end

  test "a transient failure retries then succeeds", %{bypass: bypass} do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    Bypass.expect(bypass, "POST", "/h/hb_test_token", fn conn ->
      count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:attempt, count})

      if count == 1 do
        Plug.Conn.resp(conn, 503, "unavailable")
      else
        Plug.Conn.resp(conn, 202, "{}")
      end
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token", :finish, no_sleep())
    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
  end

  test "the retry budget is bounded at 2 attempts (smaller than Observe's 3)", %{bypass: bypass} do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    Bypass.expect(bypass, "POST", "/h/hb_test_token", fn conn ->
      count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:attempt, count})
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token", :finish, no_sleep())

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
    refute_receive {:attempt, 3}, 100
  end

  test "a 429 Retry-After is ignored (never blocks on a long server-supplied delay)", %{
    bypass: bypass
  } do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    delays =
      start_supervised!(%{id: :delays_agent, start: {Agent, :start_link, [fn -> [] end]}})

    Bypass.expect(bypass, "POST", "/h/hb_test_token", fn conn ->
      count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:attempt, count})

      conn
      |> Plug.Conn.put_resp_header("retry-after", "25")
      |> Plug.Conn.resp(429, "slow down")
    end)

    sleep_fun = fn ms ->
      Agent.update(delays, &[ms | &1])
      :ok
    end

    assert :ok == AlplusSDK.heartbeat("hb_test_token", :finish, sleep_fun: sleep_fun)

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
    assert [delay] = Agent.get(delays, & &1)
    assert delay < 25_000
  end

  test "an unrecognized token (404) is swallowed, not raised", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/h/unknown_token", fn conn ->
      Plug.Conn.resp(conn, 404, "not found")
    end)

    assert :ok == AlplusSDK.heartbeat("unknown_token")
  end

  test "never raises even against an unreachable endpoint" do
    Application.put_env(:alplus_sdk, :config, base_url: "http://127.0.0.1:1")
    assert :ok == AlplusSDK.heartbeat("hb_test_token", :finish, no_sleep())
  end

  test "a base_url passed as start_link/1 opts to a running Client wins over app env/ALPLUS_ENDPOINT",
       %{bypass: _bypass} do
    other_bypass = Bypass.open()
    # App env (setup above) points at the default `bypass`; the running
    # DEFAULT-NAMED Client's own start_link opts point at `other_bypass`
    # and must win -- `heartbeat_base_url/0` only checks the default
    # `AlplusSDK.Client` name, matching `AlplusSDK.flush/1`'s own default.
    start_supervised!(
      {Client,
       key: "alp_p_test_key",
       base_url: "http://localhost:#{other_bypass.port}",
       flush_interval_ms: 0}
    )

    test_pid = self()

    Bypass.expect_once(other_bypass, "POST", "/h/hb_test_token", fn conn ->
      send(test_pid, :hit_other_bypass)
      Plug.Conn.resp(conn, 202, "{}")
    end)

    assert :ok == AlplusSDK.heartbeat("hb_test_token")
    assert_receive :hit_other_bypass, 1_000
  end

  defp no_sleep, do: [sleep_fun: fn _ms -> :ok end]
end
