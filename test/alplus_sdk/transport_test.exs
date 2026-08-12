defmodule AlplusSDK.TransportTest do
  @moduledoc """
  Asserts EXTERNAL behavior of the retry loop (attempts sent, delay
  requested, final outcome) against a real local Bypass endpoint, per issue
  #15's testing decisions. `sleep_fun` is always injected as a no-op
  recorder here -- these tests must never wait on real wall-clock time
  (the default `&Process.sleep/1` is exercised once, in the "real
  Process.sleep is the default" test below, with a tiny delay).
  """

  use ExUnit.Case, async: true

  alias AlplusSDK.Transport

  setup do
    bypass = Bypass.open()
    counter = start_supervised!({Agent, fn -> 0 end})

    delays =
      start_supervised!(%{id: :delays_agent, start: {Agent, :start_link, [fn -> [] end]}})

    sleep_fun = fn ms ->
      Agent.update(delays, &[ms | &1])
      :ok
    end

    {:ok, bypass: bypass, counter: counter, delays: delays, sleep_fun: sleep_fun}
  end

  defp recorded_delays(delays), do: delays |> Agent.get(& &1) |> Enum.reverse()

  test "a 5xx then 200 is retried to success", %{
    bypass: bypass,
    counter: counter,
    sleep_fun: sleep_fun
  } do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
      count = next_call_count(counter)
      send(test_pid, {:attempt, count})

      if count == 1 do
        Plug.Conn.resp(conn, 503, "unavailable")
      else
        Plug.Conn.resp(conn, 202, "{}")
      end
    end)

    :ok =
      Transport.request(:post, "http://localhost:#{bypass.port}/e/errors",
        body: "{}",
        headers: [{"content-type", "application/json"}],
        sleep_fun: sleep_fun
      )

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
    refute_receive {:attempt, 3}, 100
  end

  test "a 429 with Retry-After delays with the Retry-After value, not the default backoff", %{
    bypass: bypass,
    counter: counter,
    delays: delays,
    sleep_fun: sleep_fun
  } do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
      count = next_call_count(counter)
      send(test_pid, {:attempt, count})

      if count == 1 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.resp(429, "slow down")
      else
        Plug.Conn.resp(conn, 202, "{}")
      end
    end)

    :ok =
      Transport.request(:post, "http://localhost:#{bypass.port}/e/errors",
        body: "{}",
        sleep_fun: sleep_fun
      )

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
    # Retry-After: 7 -> 7000ms, not the ~250-750ms default jittered backoff.
    assert recorded_delays(delays) == [7_000]
  end

  test "a permanent 401 is dropped without retrying", %{bypass: bypass, counter: counter} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
      send(test_pid, {:attempt, next_call_count(counter)})
      Plug.Conn.resp(conn, 401, "bad key")
    end)

    :ok = Transport.request(:post, "http://localhost:#{bypass.port}/e/errors", body: "{}")

    assert_receive {:attempt, 1}, 1_000
    refute_receive {:attempt, 2}, 100
  end

  test "retries are bounded at 3 total attempts (default) against a persistently failing endpoint",
       %{bypass: bypass, counter: counter, sleep_fun: sleep_fun} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
      send(test_pid, {:attempt, next_call_count(counter)})
      Plug.Conn.resp(conn, 500, "boom")
    end)

    :ok =
      Transport.request(:post, "http://localhost:#{bypass.port}/e/errors",
        body: "{}",
        sleep_fun: sleep_fun
      )

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
    assert_receive {:attempt, 3}, 1_000
    refute_receive {:attempt, 4}, 100
  end

  test "max_attempts overrides the default retry budget (e.g. heartbeat's smaller one)", %{
    bypass: bypass,
    counter: counter,
    sleep_fun: sleep_fun
  } do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/h/tok", fn conn ->
      send(test_pid, {:attempt, next_call_count(counter)})
      Plug.Conn.resp(conn, 500, "boom")
    end)

    :ok =
      Transport.request(:post, "http://localhost:#{bypass.port}/h/tok",
        max_attempts: 2,
        sleep_fun: sleep_fun
      )

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
    refute_receive {:attempt, 3}, 100
  end

  test "honor_retry_after: false ignores Retry-After and uses the usual backoff instead", %{
    bypass: bypass,
    counter: counter,
    delays: delays,
    sleep_fun: sleep_fun
  } do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/h/tok", fn conn ->
      count = next_call_count(counter)
      send(test_pid, {:attempt, count})

      if count == 1 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "20")
        |> Plug.Conn.resp(429, "slow down")
      else
        Plug.Conn.resp(conn, 202, "{}")
      end
    end)

    :ok =
      Transport.request(:post, "http://localhost:#{bypass.port}/h/tok",
        honor_retry_after: false,
        sleep_fun: sleep_fun
      )

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
    assert [delay] = recorded_delays(delays)
    assert delay < 20_000
  end

  test "request/3 never raises even against an unreachable host" do
    assert :ok ==
             Transport.request(:post, "http://127.0.0.1:1",
               body: "{}",
               receive_timeout: 200,
               sleep_fun: fn _ms -> :ok end
             )
  end

  test "real Process.sleep/1 is the default sleep_fun", %{bypass: bypass, counter: counter} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
      count = next_call_count(counter)
      send(test_pid, {:attempt, count})

      if count == 1 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.resp(429, "slow down")
      else
        Plug.Conn.resp(conn, 202, "{}")
      end
    end)

    :ok = Transport.request(:post, "http://localhost:#{bypass.port}/e/errors", body: "{}")

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 1_000
  end

  defp next_call_count(counter), do: Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
end
