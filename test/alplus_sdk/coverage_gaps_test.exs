defmodule AlplusSDK.CoverageGapsTest.BoomMsg do
  defexception []
  def message(_), do: raise("nope")
end

defmodule AlplusSDK.CoverageGapsTest do
  use ExUnit.Case, async: false

  alias AlplusSDK.{
    Client,
    Dedup,
    Envelope,
    LoggerHandler,
    Plug,
    Scope,
    Session,
    Stack,
    Telemetry,
    Test
  }

  defp start_client(opts) do
    name = :"cov_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Client,
       Keyword.merge(
         [
           name: name,
           key: "alp_p_cov",
           test: true,
           integrations: [],
           flush_interval_ms: 20,
           batch_max_items: 2,
           debug: true
         ],
         opts
       )}
    )

    Test.reset!(name)
    name
  end

  test "delegates, default arities, and fail-safe wrappers" do
    assert is_map(AlplusSDK.child_spec([]))
    name = :"start_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             AlplusSDK.start_link(name: name, key: "x", enabled?: false, integrations: [])

    Process.exit(pid, :normal)

    assert is_binary(AlplusSDK.capture_exception(%RuntimeError{message: "x"}))
    assert is_binary(AlplusSDK.capture_message("hi"))
    assert :ok = AlplusSDK.close_session()
    assert :ok = AlplusSDK.flush()
    assert :ok = AlplusSDK.heartbeat("hb_x", :nope)

    assert :ok = AlplusSDK.set_user(%{id: 1})
    assert :ok = AlplusSDK.set_tag(:k, :v)
    assert :ok = AlplusSDK.set_context("x", %{a: 1})
    assert :ok = AlplusSDK.add_breadcrumb(%{message: "b"})
    assert :ok = AlplusSDK.set_user("bad")
    assert :ok = AlplusSDK.set_context(:x, :not_a_map)
    assert :ok = AlplusSDK.add_breadcrumb(:bad)
  end

  test "client catch paths when the process is gone" do
    name = start_client([])
    stop_supervised!(name)

    assert :ok = Client.enqueue(name, %{id: "err_x"})
    assert :ok = Client.notify_log_breadcrumb(name, %{message: "x"})
    refute Client.has_pending_exception?(name)
    assert :ok = Client.note_duplicate_capture(name, "err_x")
    assert :ok = Client.enqueue_session(name, %{id: "ses_x"})
    assert :ok = Client.flush(name, 10)
    assert :ok = Client.reset_dedup(name)
    assert {:fresh, "err_new"} = Client.resolve_dedup(name, :sig, "err_new")
  end

  test "flush timeout, disabled session enqueue, full session queue, and timer flush" do
    name = start_client(session_queue_max_items: 1, flush_interval_ms: 15, batch_max_items: 100)

    Client.enqueue_session(name, %{id: "ses_1"})
    Client.enqueue_session(name, %{id: "ses_dropped"})
    Client.enqueue(name, %{type: "message", id: "err_timer", message: "m"})
    Process.sleep(40)
    assert :ok = Client.flush(name, 1)
  end

  test "async flush of sessions only hits the empty error-batch clause" do
    name = start_client(batch_max_items: 1, flush_interval_ms: 0, post_error_log_window_ms: 0)
    Client.enqueue_session(name, %{id: "ses_only"})
    Process.sleep(20)
    assert :ok = Client.flush(name)
  end

  test "disabled client drops session items" do
    name = start_client(enabled?: false, key: "alp_p_cov")
    Client.enqueue_session(name, %{id: "ses_off"})
    assert :ok = Client.flush(name)
    assert Test.sessions(name) == []
  end

  test "debug drop of oversized envelopes" do
    huge = String.duplicate("x", 2_000_000)
    name = start_client(debug: true, post_error_log_window_ms: 0, flush_interval_ms: 0)

    pid = Process.whereis(name)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | queue: [%{type: "message", id: "err_big", message: huge}],
          queued_bytes: byte_size(huge),
          session_queue: [%{id: "ses_big", message: huge}],
          session_queued_bytes: byte_size(huge)
      }
    end)

    assert :ok = Client.flush(name)
  end

  test "pending window after-error crumbs and late seal" do
    name = start_client(post_error_log_window_ms: 30, debug: true)

    AlplusSDK.capture_exception(%RuntimeError{message: "boom"}, name: name)
    Client.notify_log_breadcrumb(name, %{message: "after", data: %{}})
    Client.notify_log_breadcrumb(name, %{message: "after2"})
    Process.sleep(50)
    Client.notify_log_breadcrumb(name, %{message: "too late"})
    assert :ok = Client.flush(name)
  end

  test "Test helpers, default names, and junk bodies" do
    name = start_client([])
    Test.record(name, :errors, "not-json")
    Test.record(name, :sessions, "{}")
    assert Test.events(name) == []
    assert Test.sessions(name) == []
    assert is_list(Test.raw(:errors))
    Test.reset!()

    tasks = for _ <- 1..8, do: Task.async(fn -> Test.record(name, :errors, "{}") end)
    Task.await_many(tasks)
  end

  test "envelope builders and cap branches" do
    assert is_binary(Envelope.sdk_name())
    assert is_binary(Envelope.sdk_version())

    assert Envelope.message_item("err_1", "hi", "info")[:type] == "message"
    session = %{id: "ses_1", status: :healthy, started_at: DateTime.utc_now()}
    assert Envelope.session_item(session).id == "ses_1"

    item =
      Envelope.exception_item("err_2", %RuntimeError{message: "x"},
        context: %{a: 1},
        contexts: "bad",
        tags: %{},
        breadcrumbs: ["nope", %{message: "ok", category: "c"}],
        fingerprint: [],
        user: %{}
      )

    assert is_map(item)

    _ =
      Envelope.exception_item("err_3", %RuntimeError{message: "x"},
        context: %{blob: String.duplicate("z", 80_000)},
        tags: %{"k" => String.duplicate("t", 80_000)},
        fingerprint: ["a", "b"],
        breadcrumbs: nil,
        user: %{id: 7}
      )

    assert Envelope.normalize_user(%{"id" => nil}) == nil
    assert Envelope.normalize_user(:nope) == nil
  end

  test "stack frames cover format, skip, and source context" do
    assert Stack.frames(:bad, [], 0) == []
    assert Stack.format_mfa(Foo, :bar, :oops) =~ "/?"
    assert Stack.format_mfa("Mod", :bar, 1) =~ "Mod.bar/1"

    assert [%{function: _}] =
             Stack.frames([{Foo, :bar, 1, [file: ~c"nope.ex", line: 1]}], [:missing], 3)

    assert Stack.frames([:garbage, %{file: "x.ex", function: "f"}], [], 0) == [
             %{file: "x.ex", function: "f"}
           ]

    path = Path.join(System.tmp_dir!(), "alplus_stack_#{System.unique_integer([:positive])}.ex")
    long = String.duplicate("a", 600)
    File.write!(path, Enum.map_join(1..5, "\n", fn i -> "#{i} #{long}" end))

    frames =
      Stack.frames(
        [{AlplusSDK.Client, :flush, 1, [file: String.to_charlist(path), line: 2]}],
        [:alplus_sdk],
        2
      )

    assert hd(frames).context_line
    assert Stack.source_context(:not_a_file, 1, 1) == %{}
    assert Stack.source_context(path, -1, 1) == %{}

    for i <- 1..257 do
      extra = Path.join(System.tmp_dir!(), "alplus_evict_#{i}.ex")
      File.write!(extra, "ok\n")
      _ = Stack.source_context(extra, 1, 1)
      File.rm(extra)
    end

    File.rm(path)
  end

  test "logger handler message shapes and crash reason fallback" do
    name = start_client([])

    :ok =
      LoggerHandler.log(%{level: :error, msg: {:string, ~c"iodata"}, meta: %{}}, %{
        config: %{name: name}
      })

    :ok =
      LoggerHandler.log(%{level: :error, msg: {"~s", ["fmt"]}, meta: %{}}, %{
        config: %{name: name}
      })

    :ok = LoggerHandler.log(%{level: :error, msg: :unknown, meta: %{}}, %{config: %{name: name}})

    :ok =
      LoggerHandler.log(%{level: :debug, msg: {:string, "dbg"}, meta: %{}}, %{
        config: %{name: name}
      })

    :ok =
      LoggerHandler.log(%{level: :notice, msg: {:string, "n"}, meta: %{}}, %{
        config: %{name: name}
      })

    :ok =
      LoggerHandler.log(
        %{level: :error, msg: {:string, "crash"}, meta: %{crash_reason: {:badarg, []}}},
        %{config: %{name: name}}
      )

    assert :ok = Client.flush(name)
  end

  test "plug, session, scope, telemetry, and dedup leftovers" do
    assert %{assigns: :ok} = Plug.call(%{assigns: :ok, not: :a_conn}, [])
    assert :ok = Session.mark_errored()
    Session.start()
    Session.start()
    assert :ok = Session.clear()
    assert :ok = Scope.set_context(:x, :nope)
    {mod, _msg} = Dedup.signature(%AlplusSDK.CoverageGapsTest.BoomMsg{})
    assert mod == AlplusSDK.CoverageGapsTest.BoomMsg
    assert match?({:term, _}, Dedup.signature(:not_an_exception))

    assert :ok = Telemetry.attach_phoenix(handler_id: :cov_tel, name: :no_such_client)
    :telemetry.execute([:phoenix, :error_rendered], %{}, %{kind: :error, reason: :boom})
    :telemetry.execute([:phoenix, :error_rendered], %{}, %{})
    Telemetry.detach(:cov_tel)
  end

  test "before_send false and non-map, heartbeat without a client" do
    name = start_client(before_send: fn _ -> :nope end)
    AlplusSDK.capture_message("x", "info", name: name)
    assert :ok = Client.flush(name)

    name2 = start_client(before_send: fn _ -> false end)
    AlplusSDK.capture_exception(%RuntimeError{message: "d"}, name: name2)
    AlplusSDK.capture_message("dropped", "info", name: name2)
    assert :ok = Client.flush(name2)

    name3 = start_client(before_send: fn _ -> nil end)
    AlplusSDK.capture_message("nil-drop", "info", name: name3)
    assert :ok = Client.flush(name3)

    assert :ok = AlplusSDK.heartbeat("hb_tok")
  end

  defmodule ViaExit do
    def send(_name, _msg), do: exit(:via_exit)
    def whereis(_name), do: nil
  end

  test "cast rescue and catch, call timeout, and default config arity" do
    assert :ok = Client.enqueue("not-a-name", %{id: "err_bad"})
    assert :ok = Client.notify_log_breadcrumb("not-a-name", %{message: "x"})
    assert :ok = Client.note_duplicate_capture("not-a-name", "err_x")
    assert :ok = Client.enqueue_session("not-a-name", %{id: "ses_x"})

    via = {:via, ViaExit, :gone}
    assert :ok = Client.enqueue(via, %{id: "err_via"})
    assert :ok = Client.notify_log_breadcrumb(via, %{message: "x"})
    assert :ok = Client.note_duplicate_capture(via, "err_via")
    assert :ok = Client.enqueue_session(via, %{id: "ses_via"})

    name = start_client([])
    pid = Process.whereis(name)
    :sys.suspend(pid)
    assert :timeout = Client.flush(name, 10)
    :sys.resume(pid)

    name2 = start_client([])
    assert %AlplusSDK.Config{} = Client.config(name2)

    unless Process.whereis(Client) do
      start_supervised!({Client, [key: "alp_p_cov", test: true, integrations: []]})
    end

    assert %AlplusSDK.Config{} = Client.config()
  end

  test "terminate flushes pending items and detaches host hooks" do
    name = :"term_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Client.start_link(
        name: name,
        key: "alp_p_cov",
        test: true,
        debug: true,
        integrations: [:logger, :phoenix],
        post_error_log_window_ms: 5_000
      )

    Client.enqueue(name, %{type: "exception", id: "err_term", message: "t"})
    Client.enqueue_session(name, %{id: "ses_term"})
    assert :ok = GenServer.stop(pid, :normal)
    refute Process.alive?(pid)
  end

  test "unknown seal, empty timer flush, and breadcrumb caps" do
    name = start_client(post_error_log_window_ms: 5_000, batch_max_items: 100)
    pid = Process.whereis(name)
    send(pid, :flush_timer)
    send(pid, {:seal_pending, make_ref()})
    assert :ok = Client.note_duplicate_capture(name, "err_missing")

    AlplusSDK.capture_exception(%RuntimeError{message: "cap"}, name: name)
    crumbs = for i <- 1..100, do: %{message: "c#{i}"}

    Client.enqueue(name, %{
      type: "exception",
      id: "err_full",
      breadcrumbs: crumbs
    })

    Client.notify_log_breadcrumb(name, %{message: "overflow", data: %{keep: true}})
    Client.notify_log_breadcrumb(name, %{message: "overflow2"})
    assert :ok = Client.flush(name)
  end

  test "duplicate note keeps matching id and seals a different pending id" do
    name = start_client(post_error_log_window_ms: 5_000)
    AlplusSDK.capture_exception(%RuntimeError{message: "keep"}, name: name)
    [item] = :sys.get_state(name).pending |> Map.values()
    Client.note_duplicate_capture(name, item.item[:id] || item.item["id"])

    Client.enqueue(name, %{type: "exception", id: "err_other"})
    Client.note_duplicate_capture(name, "err_not_this")
    assert :ok = Client.flush(name)
  end

  test "flush rescue, capture rescue, heartbeat rescue, and fetch_config exit" do
    assert :ok = AlplusSDK.flush(:not_keyword)
    assert is_binary(AlplusSDK.capture_message("x", "info", :not_keyword))
    assert :ok = AlplusSDK.heartbeat(:not_a_token)

    name = start_client([])
    Process.put(:__alplus_sdk_scope__, :not_a_scope)
    assert is_binary(AlplusSDK.capture_exception(%RuntimeError{message: "x"}, name: name))
    Process.delete(:__alplus_sdk_scope__)

    AlplusSDK.Session.start()
    assert :ok = AlplusSDK.close_session(:not_keyword)

    name = :"gone_#{System.unique_integer([:positive])}"
    AlplusSDK.Session.start()
    assert :ok = AlplusSDK.close_session(name: name)

    name2 = :"cfg_#{System.unique_integer([:positive])}"

    pid =
      spawn(fn ->
        receive do
          _ -> exit(:boom)
        end
      end)

    Process.register(pid, name2)
    assert is_binary(AlplusSDK.capture_exception(%RuntimeError{message: "gone"}, name: name2))
  end

  test "before_send raise, sampled-out, and message nil before_send" do
    name = start_client(before_send: fn _ -> raise "nope" end)
    AlplusSDK.capture_exception(%RuntimeError{message: "x"}, name: name)
    AlplusSDK.capture_message("m", "info", name: name)
    assert :ok = Client.flush(name)

    name2 = start_client(sample_rate: 0.0)
    assert is_binary(AlplusSDK.capture_exception(%RuntimeError{message: "s"}, name: name2))
    assert is_binary(AlplusSDK.capture_message("s", "error", name: name2))
  end

  test "async flush failure, encode failure, and oversized session envelope" do
    name = start_client(debug: true, post_error_log_window_ms: 0, batch_max_items: 1)
    pid = Process.whereis(name)
    dead = spawn(fn -> :ok end)
    :sys.replace_state(pid, fn state -> %{state | task_sup: dead} end)
    Client.enqueue(name, %{type: "message", id: "err_async", message: "x"})
    Process.sleep(20)

    name2 = start_client(debug: true, post_error_log_window_ms: 0, flush_interval_ms: 0)
    pid2 = Process.whereis(name2)

    :sys.replace_state(pid2, fn state ->
      %{
        state
        | queue: [%{id: "err_ref", bad: make_ref()}],
          queued_bytes: 1,
          session_queue: [%{id: "ses_ref", bad: make_ref()}],
          session_queued_bytes: 1
      }
    end)

    assert :ok = Client.flush(name2)

    huge = String.duplicate("s", 2_000_000)
    name3 = start_client(debug: true, post_error_log_window_ms: 0, flush_interval_ms: 0)
    pid3 = Process.whereis(name3)

    :sys.replace_state(pid3, fn state ->
      %{state | session_queue: [%{id: "ses_huge", blob: huge}], session_queued_bytes: 2_000_000}
    end)

    assert :ok = Client.flush(name3)
  end

  test "sync flush timeout when the task supervisor is dead" do
    name = start_client(debug: true, post_error_log_window_ms: 0)
    pid = Process.whereis(name)
    dead = spawn(fn -> :ok end)
    :sys.replace_state(pid, fn state -> %{state | task_sup: dead} end)
    Client.enqueue(name, %{type: "message", id: "err_sync", message: "x"})
    Client.enqueue_session(name, %{id: "ses_sync"})
    assert :ok = Client.flush(name)
  end

  test "scope update rescue, session bump rescue, and logger handler rescues" do
    Process.put(:__alplus_sdk_scope__, :not_a_scope)
    assert :ok = AlplusSDK.Scope.set_tag("k", "v")

    Process.put(:__alplus_sdk_session__, :not_a_session)
    assert :ok = AlplusSDK.Session.mark_errored()
    assert :ok = AlplusSDK.Session.mark_crashed()

    assert :ok = LoggerHandler.log(%{level: :error, meta: :bad}, %{})
    assert :ok = LoggerHandler.log(%{level: :warning}, nil)

    name = start_client([])

    assert :ok =
             LoggerHandler.log(%{level: :error, msg: {"~s", []}, meta: %{}}, %{
               config: %{name: name}
             })

    assert :ok =
             LoggerHandler.log(%{level: :error, msg: {:string, ~c"plain"}, meta: %{}}, %{
               config: %{name: name, logger_breadcrumbs: false}
             })

    assert :ok =
             LoggerHandler.log(%{level: :info, msg: {:string, "skip"}, meta: %{}}, %{
               config: %{name: name, logger_breadcrumbs: false}
             })

    assert :ok = Client.flush(name)
  end

  test "plug rescues, request headers, and telemetry defaults" do
    assert %{assigns: %{}} = Plug.call(%{assigns: %{}}, :not_keyword)

    assert %{assigns: %{}} =
             Plug.call(%{assigns: %{}, req_headers: [:bad]}, [])

    conn = %{
      assigns: %{},
      method: "GET",
      host: "ex.test",
      request_path: "/",
      req_headers: [{"user-agent", "ua"}, {"x-other", "nope"}]
    }

    assert is_map(Plug.call(conn, []))
    assert is_map(Plug.call(%{assigns: %{}, req_headers: []}, []))

    assert :ok = Telemetry.attach_phoenix()
    :telemetry.execute([:phoenix, :error_rendered], %{}, %{status: 404})
    :telemetry.execute([:phoenix, :error_rendered], %{}, %{reason: %RuntimeError{message: "e"}})
    :telemetry.execute([:phoenix, :error_rendered], %{}, %{hello: :world})
    Telemetry.detach()
  end

  test "stack unreadable file and envelope leftover caps" do
    path =
      Path.join(System.tmp_dir!(), "alplus_unreadable_#{System.unique_integer([:positive])}.ex")

    File.write!(path, "ok\n")
    File.chmod!(path, 0o000)
    assert Stack.source_context(path, 1, 1) == %{}
    File.chmod!(path, 0o644)
    File.rm(path)

    frames = [%{file: "huge.ex", function: String.duplicate("f", 20_000)}]
    _ = Envelope.exception_item("err_frames", %RuntimeError{message: "x"}, stacktrace: frames)

    path2 = Path.join(System.tmp_dir!(), "alplus_cache_#{System.unique_integer([:positive])}.ex")
    File.write!(path2, "ok\n")
    _ = Stack.source_context(path2, 1, 1)
    assert Stack.create_source_cache_table()
    :ets.insert(AlplusSDK.Stack.SourceCache, {path2, [1, 2, 3]})
    assert Stack.source_context(path2, 1, 1) == %{}
    File.rm(path2)

    _ =
      Envelope.exception_item("err_cause", %RuntimeError{message: "x"},
        cause: %RuntimeError{message: "inner"},
        cause_stacktrace: [{Foo, :bar, 1, [file: ~c"x.ex", line: 1]}],
        breadcrumbs: :not_a_list,
        fingerprint: [nil]
      )

    _ = Envelope.message_item("err_m", "hi", "info", context: %{a: 1}, contexts: "bad")
    _ = Envelope.message_item("err_m2", "hi", "info", contexts: %{})
  end

  test "transport debug, invalid retry opts, and request rescue" do
    assert :ok = AlplusSDK.Transport.request(:post, :not_a_url, debug: true)

    assert :ok =
             AlplusSDK.Transport.request(:post, "http://127.0.0.1:1/",
               debug: true,
               max_attempts: :bad,
               honor_retry_after: :no,
               sleep_fun: :bad
             )
  end

  test "Test default names and already-started recorder" do
    if pid = Process.whereis(AlplusSDK.Test) do
      Process.unregister(AlplusSDK.Test)
      assert is_pid(pid)
    end

    Test.record(AlplusSDK.Client, :errors, "{}")
    assert is_list(Test.events())
    assert is_list(Test.sessions())
    assert :ok = Test.start_recorder()
    Test.reset!()
  end

  test "Dedup message rescue and Client generate_id" do
    assert {AlplusSDK.CoverageGapsTest.BoomMsg, nil} =
             Dedup.signature(%AlplusSDK.CoverageGapsTest.BoomMsg{})

    assert is_binary(Client.generate_id())
  end
end
