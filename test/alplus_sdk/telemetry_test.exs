defmodule AlplusSDK.TelemetryTest do
  use ExUnit.Case, async: false

  alias AlplusSDK.{Client, Telemetry}

  setup do
    bypass = Bypass.open()
    name = :"telemetry_client_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Client,
       name: name,
       key: "alp_p_test_key_123",
       base_url: "http://localhost:#{bypass.port}",
       flush_interval_ms: 0,
       batch_max_items: 1_000}
    )

    handler_id = :"telemetry_test_#{System.unique_integer([:positive])}"
    :ok = Telemetry.attach_phoenix(name: name, handler_id: handler_id)
    on_exit(fn -> Telemetry.detach(handler_id) end)

    {:ok, bypass: bypass, name: name}
  end

  test "a 500 [:phoenix, :error_rendered] event is captured", %{bypass: bypass, name: name} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, raw_body})
      Plug.Conn.resp(conn, 202, "{}")
    end)

    :telemetry.execute([:phoenix, :error_rendered], %{duration: 1_000}, %{
      status: 500,
      kind: :error,
      reason: %RuntimeError{message: "controller blew up"},
      stacktrace: [{Kernel, :apply, 2, []}],
      log: :error
    })

    assert :ok == Client.flush(name, 1_000)
    assert_receive {:request, raw_body}, 1_000

    %{"items" => [item]} = Jason.decode!(raw_body)
    assert item["type"] == "exception"
    assert item["exception"]["type"] == "RuntimeError"
    assert item["exception"]["value"] == "controller blew up"
    assert item["mechanism"] == "phoenix.error_rendered"
  end

  test "a 404 [:phoenix, :error_rendered] event is not captured", %{bypass: bypass, name: name} do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/e/errors", fn conn ->
      send(test_pid, :unexpected_request)
      Plug.Conn.resp(conn, 202, "{}")
    end)

    :telemetry.execute([:phoenix, :error_rendered], %{duration: 1_000}, %{
      status: 404,
      kind: :error,
      reason: :no_route,
      stacktrace: [],
      log: :debug
    })

    assert :ok == Client.flush(name, 1_000)
    refute_receive :unexpected_request, 200
  end
end
