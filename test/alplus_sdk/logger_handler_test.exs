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
       batch_max_items: 1_000,
       integrations: []}
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

  describe "log-line breadcrumbs and the post-error window (issue #47)" do
    test "a sub-error line becomes a log breadcrumb on the logging process's scope" do
      AlplusSDK.Scope.clear()
      :logger.log(:info, "importing roll", %{})
      :logger.log(:warning, "row 41 blank", %{})

      crumbs =
        AlplusSDK.Scope.current().breadcrumbs
        |> Enum.filter(&(&1[:category] == "log"))
        |> Enum.uniq_by(&{&1.message, &1.level})

      assert [
               %{message: "importing roll", level: "info"},
               %{message: "row 41 blank", level: "warning"}
             ] = crumbs

      assert Enum.all?(crumbs, &is_binary(&1[:ts]))
    end

    test "the SDK's own alplus_sdk lines and disabled handlers record nothing", %{name: name} do
      AlplusSDK.Scope.clear()
      :logger.log(:debug, "alplus_sdk: dropping oversized envelope", %{})

      disabled_id = :"disabled_handler_#{System.unique_integer([:positive])}"

      :logger.add_handler(disabled_id, LoggerHandler, %{
        config: %{name: name, logger_breadcrumbs: false}
      })

      on_exit(fn -> :logger.remove_handler(disabled_id) end)

      assert AlplusSDK.Scope.current().breadcrumbs
             |> Enum.filter(&(&1[:category] == "log"))
             |> Enum.empty?()
    end

    test "a log line after capture joins the sealed event, marked after_error", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_exception(%RuntimeError{message: "boom"}, name: name)
      :logger.log(:warning, "retrying gateway after failure", %{})

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000

      %{"items" => [item]} = Jason.decode!(raw_body)

      after_crumb =
        Enum.find(item["breadcrumbs"], &(&1["message"] == "retrying gateway after failure"))

      assert after_crumb["data"] == %{"after_error" => true}
      assert after_crumb["level"] == "warning"
    end

    test "the window seals and delivers on its own once it elapses", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sealed_request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      windowed = :"windowed_client_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Client,
         name: windowed,
         key: "alp_p_test_key_123",
         base_url: "http://localhost:#{bypass.port}",
         flush_interval_ms: 0,
         batch_max_items: 1,
         post_error_log_window_ms: 50,
         integrations: []}
      )

      AlplusSDK.capture_exception(%RuntimeError{message: "boom"}, name: windowed)
      assert_receive {:sealed_request, _raw_body}, 2_000
    end

    test "Logger.error after capture joins the pending event, not a second issue", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.Scope.clear()
      AlplusSDK.capture_exception(%RuntimeError{message: "boom"}, name: name)
      :logger.log(:error, "Import aborted: key missing", %{})

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000

      %{"items" => items} = Jason.decode!(raw_body)
      assert length(items) == 1
      [item] = items
      assert item["type"] == "exception"

      after_crumb =
        Enum.find(item["breadcrumbs"], &(&1["message"] == "Import aborted: key missing"))

      assert after_crumb["level"] == "error"
      assert after_crumb["data"] == %{"after_error" => true}
    end

    test "a second capture seals the first so later logs do not leak onto it", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.Scope.clear()
      first = AlplusSDK.capture_exception(%RuntimeError{message: "first"}, name: name)
      second = AlplusSDK.capture_exception(%RuntimeError{message: "second"}, name: name)
      :logger.log(:warning, "only for second", %{})

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      items = Jason.decode!(raw_body)["items"]

      first_item = Enum.find(items, &(&1["id"] == first))
      second_item = Enum.find(items, &(&1["id"] == second))

      first_crumbs = first_item["breadcrumbs"] || []
      refute Enum.any?(first_crumbs, &(&1["message"] == "only for second"))

      after_crumb =
        Enum.find(second_item["breadcrumbs"] || [], &(&1["message"] == "only for second"))

      assert after_crumb["data"] == %{"after_error" => true}
    end

    test "a same-signature duplicate keeps the post-error window", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.Scope.clear()
      first = AlplusSDK.capture_exception(%RuntimeError{message: "wrapper"}, name: name)
      _dup = AlplusSDK.capture_exception(%RuntimeError{message: "wrapper"}, name: name)
      :logger.log(:warning, "after duplicate", %{})

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      items = Jason.decode!(raw_body)["items"]
      first_item = Enum.find(items, &(&1["id"] == first))
      crumbs = first_item["breadcrumbs"] || []
      assert Enum.any?(crumbs, &(&1["message"] == "after duplicate"))
    end

    test "a duplicate of an earlier exception seals a different pending item", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.Scope.clear()
      key_id = AlplusSDK.capture_exception(%KeyError{key: :a, term: %{}}, name: name)
      wrap_id = AlplusSDK.capture_exception(%RuntimeError{message: "wrapper"}, name: name)
      _dup = AlplusSDK.capture_exception(%KeyError{key: :a, term: %{}}, name: name)
      :logger.log(:warning, "should not leak onto wrapper", %{})

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      items = Jason.decode!(raw_body)["items"]

      wrap_item = Enum.find(items, &(&1["id"] == wrap_id))
      wrap_crumbs = wrap_item["breadcrumbs"] || []
      refute Enum.any?(wrap_crumbs, &(&1["message"] == "should not leak onto wrapper"))

      key_item = Enum.find(items, &(&1["id"] == key_id))
      key_crumbs = key_item["breadcrumbs"] || []
      refute Enum.any?(key_crumbs, &(&1["message"] == "should not leak onto wrapper"))
    end

    test "another process's log lines never join this process's pending event", %{
      bypass: bypass,
      name: name
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_exception(%RuntimeError{message: "boom"}, name: name)

      Task.async(fn -> :logger.log(:warning, "other process noise", %{}) end)
      |> Task.await()

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000

      %{"items" => [item]} = Jason.decode!(raw_body)
      crumbs = item["breadcrumbs"] || []
      refute Enum.any?(crumbs, &(&1["message"] == "other process noise"))
    end
  end
end
