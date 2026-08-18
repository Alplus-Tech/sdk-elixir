defmodule AlplusSDKTest do
  use ExUnit.Case, async: true

  alias AlplusSDK.Client

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  defp start_client(bypass, opts \\ []) do
    name = :"client_#{System.unique_integer([:positive])}"

    default_opts = [
      name: name,
      key: "alp_p_test_key_123",
      base_url: "http://localhost:#{bypass.port}",
      environment: "test",
      release: "1.2.3",
      # Deterministic tests: disable the idle timer, flush explicitly.
      flush_interval_ms: 0,
      batch_max_items: 100,
      batch_max_bytes: 1_000_000,
      integrations: []
    ]

    start_supervised!({Client, Keyword.merge(default_opts, opts)})
    name
  end

  describe "golden envelope" do
    test "a captured exception produces the documented POST /e/errors wire shape", %{
      bypass: bypass
    } do
      name = start_client(bypass)

      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn, raw_body})
        Plug.Conn.resp(conn, 202, Jason.encode!(%{accepted: 1, dropped: 0}))
      end)

      exception = %RuntimeError{message: "boom"}

      # AlplusSDK.Client genuinely belongs to the :alplus_sdk OTP app (loaded
      # at test-run time), so `Application.get_application/1` resolves it --
      # a made-up module like `MyApp.Worker` would not be, and would always
      # report `in_app: false` regardless of `in_app_otp_apps`.
      stacktrace = [
        {AlplusSDK.Client, :do_flush, 1, [file: ~c"lib/alplus_sdk/client.ex", line: 42]},
        {:erlang, :apply, 2, []}
      ]

      event_id =
        AlplusSDK.capture_exception(exception,
          name: name,
          stacktrace: stacktrace,
          tags: %{"customer" => "acme"},
          in_app_otp_apps: [:alplus_sdk]
        )

      assert String.starts_with?(event_id, "err_")
      assert :ok == Client.flush(name, 1_000)

      assert_receive {:request, conn, raw_body}
      assert [<<"Bearer alp_p_test_key_123">>] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")

      envelope = Jason.decode!(raw_body)

      assert %{
               "header" => %{
                 "key" => "alp_p_test_key_123",
                 "sdk" => %{
                   "name" => "alplus-elixir",
                   "version" => _version,
                   "platform" => "elixir"
                 },
                 "sent_at" => sent_at
               },
               "items" => [item]
             } = envelope

      assert {:ok, _, _} = DateTime.from_iso8601(sent_at)

      assert %{
               "id" => ^event_id,
               "type" => "exception",
               "level" => "error",
               "release" => "1.2.3",
               "environment" => "test",
               "mechanism" => "generic",
               "tags" => %{"customer" => "acme"},
               "exception" => %{
                 "type" => "RuntimeError",
                 "value" => "boom",
                 "stacktrace" => %{
                   "frames" => [
                     %{
                       "function" => "AlplusSDK.Client.do_flush/1",
                       "file" => "lib/alplus_sdk/client.ex",
                       "lineno" => 42,
                       "in_app" => true
                     },
                     frame_2
                   ]
                 }
               }
             } = item

      assert frame_2["in_app"] == false
      assert {:ok, _, _} = DateTime.from_iso8601(item["timestamp"])
    end
  end

  describe "capture_message/3" do
    test "sends a message item with the given level", %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      id = AlplusSDK.capture_message("disk usage high", "warning", name: name)
      assert :ok == Client.flush(name)

      assert_receive {:request, raw_body}
      %{"items" => [item]} = Jason.decode!(raw_body)
      assert item["id"] == id
      assert item["type"] == "message"
      assert item["level"] == "warning"
      assert item["message"] == "disk usage high"
    end

    test "a non-binary message never raises and is stringified", %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      id = AlplusSDK.capture_message(%{unexpected: :map}, "info", name: name)
      assert String.starts_with?(id, "err_")
      assert :ok == Client.flush(name)

      assert_receive {:request, raw_body}
      %{"items" => [item]} = Jason.decode!(raw_body)
      assert item["message"] =~ "unexpected"
    end
  end

  describe "scope options" do
    test "contexts, breadcrumbs, fingerprint, and user are carried onto the item", %{
      bypass: bypass
    } do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_exception(%RuntimeError{message: "scoped"},
        name: name,
        contexts: %{"extra" => %{"order_id" => "abc123"}},
        breadcrumbs: [%{"category" => "http", "message" => "GET /orders", "level" => "info"}],
        fingerprint: ["custom", "group"],
        user: %{"id" => "user_42", "email" => "dev@example.com"}
      )

      assert :ok == Client.flush(name)
      assert_receive {:request, raw_body}

      %{"items" => [item]} = Jason.decode!(raw_body)
      assert item["contexts"] == %{"extra" => %{"order_id" => "abc123"}}

      assert item["breadcrumbs"] == [
               %{"category" => "http", "message" => "GET /orders", "level" => "info"}
             ]

      assert item["fingerprint"] == ["custom", "group"]
      assert item["user"] == %{"id" => "user_42", "email" => "dev@example.com"}
    end
  end

  describe "size caps (parity with the JS/Ruby SDKs)" do
    test "oversized contexts are replaced with a truncation marker, not dropped from the send", %{
      bypass: bypass
    } do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      # > MAX_CONTEXT_CHARS (8192) once JSON-encoded.
      oversized = %{"extra" => %{"blob" => String.duplicate("x", 9_000)}}

      AlplusSDK.capture_exception(%RuntimeError{message: "big context"},
        name: name,
        contexts: oversized
      )

      assert :ok == Client.flush(name)
      assert_receive {:request, raw_body}

      %{"items" => [item]} = Jason.decode!(raw_body)
      assert item["contexts"]["_truncated"] == true
      assert is_integer(item["contexts"]["_original_chars"])
      assert item["contexts"]["_original_chars"] > 8_192
      refute Map.has_key?(item["contexts"], "extra")
    end

    test "stack frames are trimmed to fit MAX_STACK_TRACE_CHARS, keeping the top frames", %{
      bypass: bypass
    } do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      # 300 frames comfortably exceeds MAX_STACK_TRACE_CHARS (16384) once
      # JSON-encoded; each entry names a distinct, real, loaded module
      # (AlplusSDK.Client) so `Application.get_application/1` still resolves.
      big_stacktrace =
        for n <- 1..300 do
          {AlplusSDK.Client, :"frame_#{n}", 0, [file: ~c"lib/alplus_sdk/client.ex", line: n]}
        end

      AlplusSDK.capture_exception(%RuntimeError{message: "deep stack"},
        name: name,
        stacktrace: big_stacktrace
      )

      assert :ok == Client.flush(name)
      assert_receive {:request, raw_body}

      %{"items" => [item]} = Jason.decode!(raw_body)
      frames = item["exception"]["stacktrace"]["frames"]

      assert length(frames) < 300
      assert byte_size(Jason.encode!(frames)) <= 16_384
      # Top (earliest) frames are kept; trailing frames are dropped first.
      assert hd(frames)["function"] == "AlplusSDK.Client.frame_1/0"
    end

    test "breadcrumb count is capped at SERVER_MAX_BREADCRUMBS, keeping the most recent", %{
      bypass: bypass
    } do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      breadcrumbs = for n <- 1..150, do: %{"category" => "nav", "message" => "step #{n}"}

      AlplusSDK.capture_exception(%RuntimeError{message: "many crumbs"},
        name: name,
        breadcrumbs: breadcrumbs
      )

      assert :ok == Client.flush(name)
      assert_receive {:request, raw_body}

      %{"items" => [item]} = Jason.decode!(raw_body)
      assert length(item["breadcrumbs"]) == 100
      # Most recent (highest-numbered) 100 kept, oldest dropped.
      assert List.first(item["breadcrumbs"])["message"] == "step 51"
      assert List.last(item["breadcrumbs"])["message"] == "step 150"
    end

    test "breadcrumb category/message are truncated per-field", %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_message("check crumb caps", "info",
        name: name,
        breadcrumbs: [
          %{
            "category" => String.duplicate("c", 200),
            "message" => String.duplicate("m", 3_000)
          }
        ]
      )

      assert :ok == Client.flush(name)
      assert_receive {:request, raw_body}

      %{"items" => [item]} = Jason.decode!(raw_body)
      [crumb] = item["breadcrumbs"]
      assert String.length(crumb["category"]) == 128
      assert String.length(crumb["message"]) == 2_048
    end
  end

  describe "batching" do
    test "flushes automatically once batch_max_items is reached", %{bypass: bypass} do
      name = start_client(bypass, batch_max_items: 2)
      test_pid = self()

      Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_message("one", "info", name: name)
      AlplusSDK.capture_message("two", "info", name: name)

      assert_receive {:request, raw_body}, 1_000
      %{"items" => items} = Jason.decode!(raw_body)
      assert length(items) == 2
    end
  end

  describe "fail-safe transport" do
    test "a 500 response is retried up to 3 attempts then swallowed, not raised", %{
      bypass: bypass
    } do
      name = start_client(bypass)

      # 500 is retryable (not one of the permanent 400/401/403/404
      # statuses), so the transport's retry loop hits this endpoint up to
      # `@max_attempts` (3) times before giving up -- `expect/4` (not
      # `expect_once/4`) allows every one of those calls.
      Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      AlplusSDK.capture_message("will 500", "error", name: name)
      assert :ok == Client.flush(name, 5_000)
    end

    test "a connection failure (endpoint down) is swallowed, not raised", %{bypass: bypass} do
      name = start_client(bypass)
      Bypass.down(bypass)

      AlplusSDK.capture_message("endpoint is down", "error", name: name)
      assert :ok == Client.flush(name, 5_000)
    end

    test "capture_exception/2 never raises even with a garbage stacktrace", %{bypass: bypass} do
      name = start_client(bypass)
      Bypass.down(bypass)

      id =
        AlplusSDK.capture_exception(:not_an_exception,
          name: name,
          stacktrace: :not_a_stacktrace
        )

      assert String.starts_with?(id, "err_")
      assert :ok == Client.flush(name, 5_000)
    end

    test "calling capture_* with no client started never raises and never hits the network" do
      id =
        AlplusSDK.capture_exception(%RuntimeError{message: "no client"},
          name: :nonexistent_client
        )

      assert String.starts_with?(id, "err_")
      assert :ok == AlplusSDK.flush(name: :nonexistent_client)
    end
  end

  describe "test/noop mode" do
    test "enabled?: false never enqueues or hits the network", %{bypass: bypass} do
      name = start_client(bypass, enabled?: false)

      # No `Bypass.expect*/2,4` stub is registered: if the SDK ignored
      # `enabled?: false` and made a request anyway, Bypass itself would
      # raise ("no expectation set") and fail this test on `on_exit`.
      id = AlplusSDK.capture_exception(%RuntimeError{message: "should be dropped"}, name: name)
      assert String.starts_with?(id, "err_")
      assert :ok == Client.flush(name, 1_000)
    end
  end

  describe "ingest key never logged" do
    test "inspecting the resolved config redacts the key", %{bypass: bypass} do
      name = start_client(bypass)
      config = Client.config(name)

      refute inspect(config) =~ "alp_p_test_key_123"
      assert inspect(config) =~ "[REDACTED]"
    end
  end

  describe "capture_exception/2 dedup (issue #15)" do
    test "the same error captured twice within the window reports once", %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      exception = %RuntimeError{message: "duplicate me"}

      id1 = AlplusSDK.capture_exception(exception, name: name)
      id2 = AlplusSDK.capture_exception(exception, name: name)

      assert id1 == id2
      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000

      %{"items" => items} = Jason.decode!(raw_body)
      assert length(items) == 1
      assert hd(items)["id"] == id1

      # No second request: `Bypass.expect_once/4` would fail `on_exit` if
      # the duplicate had been enqueued and flushed too.
    end

    test "a structurally different error is not deduplicated", %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      id1 = AlplusSDK.capture_exception(%RuntimeError{message: "one"}, name: name)
      id2 = AlplusSDK.capture_exception(%RuntimeError{message: "two"}, name: name)

      assert id1 != id2
      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      %{"items" => items} = Jason.decode!(raw_body)
      assert length(items) == 2
    end
  end

  describe "scope options (issue #17)" do
    test "AlplusSDK.Scope ambient values are carried onto the item and merged with per-call opts",
         %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      AlplusSDK.Scope.clear()
      AlplusSDK.Scope.set_user(%{"id" => "ambient_user"})
      AlplusSDK.Scope.set_tag("ambient_tag", "yes")
      AlplusSDK.Scope.set_context("request", %{"path" => "/orders"})
      AlplusSDK.Scope.add_breadcrumb(%{"category" => "nav", "message" => "ambient crumb"})

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_exception(%RuntimeError{message: "scoped by ambient"},
        name: name,
        tags: %{"call_tag" => "override"},
        breadcrumbs: [%{"category" => "http", "message" => "call crumb"}]
      )

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      %{"items" => [item]} = Jason.decode!(raw_body)

      assert item["user"] == %{"id" => "ambient_user"}
      assert item["tags"] == %{"ambient_tag" => "yes", "call_tag" => "override"}
      assert item["contexts"]["request"] == %{"path" => "/orders"}

      assert item["breadcrumbs"] == [
               %{"category" => "nav", "message" => "ambient crumb"},
               %{"category" => "http", "message" => "call crumb"}
             ]

      AlplusSDK.Scope.clear()
    end

    test "an explicit user: nil override clears the ambient user for that one capture", %{
      bypass: bypass
    } do
      name = start_client(bypass)
      test_pid = self()

      AlplusSDK.Scope.clear()
      AlplusSDK.Scope.set_user(%{"id" => "ambient_user"})

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_exception(%RuntimeError{message: "cleared user"}, name: name, user: nil)

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      %{"items" => [item]} = Jason.decode!(raw_body)
      refute Map.has_key?(item, "user")

      AlplusSDK.Scope.clear()
    end

    test "the :context convenience option folds into contexts.extra", %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_exception(%RuntimeError{message: "with context"},
        name: name,
        contexts: %{"named" => %{"a" => 1}},
        context: %{"order_id" => "abc123"}
      )

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      %{"items" => [item]} = Jason.decode!(raw_body)

      assert item["contexts"] == %{
               "named" => %{"a" => 1},
               "extra" => %{"order_id" => "abc123"}
             }
    end

    test "a user with a non-binary id (a normal Phoenix integer PK) is stringified, not dropped",
         %{bypass: bypass} do
      name = start_client(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/e/errors", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, raw_body})
        Plug.Conn.resp(conn, 202, "{}")
      end)

      AlplusSDK.capture_exception(%RuntimeError{message: "integer pk user"},
        name: name,
        user: %{id: 12_345, email: "dev@example.com"}
      )

      assert :ok == Client.flush(name, 1_000)
      assert_receive {:request, raw_body}, 1_000
      %{"items" => [item]} = Jason.decode!(raw_body)

      assert item["user"] == %{"id" => "12345", "email" => "dev@example.com"}
    end
  end

  describe "sample_rate (issue #17)" do
    test "sample_rate 0.0 drops the capture without hitting the network", %{bypass: bypass} do
      name = start_client(bypass, sample_rate: 0.0)

      # No `Bypass.expect*/2,4` stub is registered: a request would fail
      # `on_exit` the same way `enabled?: false`'s test above relies on.
      id = AlplusSDK.capture_message("should be sampled out", "info", name: name)
      assert String.starts_with?(id, "err_")
      assert :ok == Client.flush(name, 1_000)
    end

    test "a sampled-out capture does not poison dedup for a later sampled-in capture of the same error",
         %{bypass: bypass} do
      name = start_client(bypass, sample_rate: 0.0)
      exception = %RuntimeError{message: "sampled out then dedup-checked"}

      # sample_rate: 0.0 drops every capture, so this must never register a
      # dedup entry -- if it did (the bug this test guards against),
      # `Client.resolve_dedup/3` below would come back `:duplicate` even
      # though nothing was ever actually sent for this signature.
      AlplusSDK.capture_exception(exception, name: name)
      AlplusSDK.capture_exception(exception, name: name)

      assert {:fresh, "probe_id"} ==
               Client.resolve_dedup(name, AlplusSDK.Dedup.signature(exception), "probe_id")
    end
  end
end
