defmodule AlplusSDK.LoggerHandlerTest do
  use ExUnit.Case, async: false

  alias AlplusSDK.{Client, LoggerHandler}

  setup do
    bypass = Bypass.open()
    name = :"logger_handler_client_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Client,
       name: name,
       key: "alp_p_test_key_123",
       base_url: "http://localhost:#{bypass.port}",
       flush_interval_ms: 0,
       batch_max_items: 1_000}
    )

    handler_id = :"logger_handler_test_#{System.unique_integer([:positive])}"
    :logger.add_handler(handler_id, LoggerHandler, %{config: %{name: name}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    {:ok, bypass: bypass, name: name}
  end

  test "a crash_reason report is captured as an exception", %{bypass: bypass, name: name} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, raw_body})
      Plug.Conn.resp(conn, 202, "{}")
    end)

    :logger.log(:error, "process crashed", %{
      crash_reason: {%RuntimeError{message: "kaboom"}, [{Kernel, :apply, 2, []}]}
    })

    assert :ok == Client.flush(name, 1_000)
    assert_receive {:request, raw_body}, 1_000

    %{"items" => [item]} = Jason.decode!(raw_body)
    assert item["type"] == "exception"
    assert item["exception"]["type"] == "RuntimeError"
    assert item["exception"]["value"] == "kaboom"
    assert item["mechanism"] == "logger"
  end

  test "a plain Logger.error/1 call is captured as a message", %{bypass: bypass, name: name} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, raw_body})
      Plug.Conn.resp(conn, 202, "{}")
    end)

    :logger.log(:error, "a deliberate error log line", %{})

    assert :ok == Client.flush(name, 1_000)
    assert_receive {:request, raw_body}, 1_000

    %{"items" => [item]} = Jason.decode!(raw_body)
    assert item["type"] == "message"
    assert item["message"] == "a deliberate error log line"
    assert item["level"] == "error"
  end

  test "an info-level report is not captured", %{bypass: bypass, name: name} do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/e/errors", fn conn ->
      send(test_pid, :unexpected_request)
      Plug.Conn.resp(conn, 202, "{}")
    end)

    :logger.log(:info, "just fyi", %{})
    assert Client.flush(name, 1_000) == :ok
    refute_receive :unexpected_request, 200
  end

  test "the handler never raises back into :logger on a malformed event" do
    assert :ok == LoggerHandler.log(%{level: :error, meta: %{crash_reason: :not_a_tuple}}, %{})
    assert :ok == LoggerHandler.log(%{level: :error}, %{})
  end
end
