defmodule AlplusSDK.WireCompatTest do
  @moduledoc """
  Asserts the envelope this SDK builds only uses keys the server's real
  parser (`lib/alplus/observe/error_envelope.ex` in the monolith, at the
  repo root two levels up from `sdks/elixir/`) accepts.

  This package cannot take a `:test`-only path dep on the monolith app: the
  monolith pulls in Ash, Phoenix, and the full Ecto/Postgres stack, which
  would make this SDK's own `mix test` require a running Postgres and a
  multi-minute compile -- unacceptable for a package whose entire point is
  to be a small, dependency-light client. Instead, this fixture copies the
  parser's exact accepted-key lists by hand (`exact_keys?/2` in the source
  file above rejects any key outside these lists). If the server's parser
  changes its accepted keys, update this fixture to match -- a mismatch
  here means either this SDK is sending a key the server will now reject,
  or the server started accepting a field this SDK doesn't emit.
  """

  use ExUnit.Case, async: true

  alias AlplusSDK.{Config, Envelope}

  @header_keys ~w(key sdk sent_at)
  @sdk_keys ~w(name version platform)
  @item_keys ~w(id type timestamp level release environment message exception fingerprint breadcrumbs contexts tags user mechanism)
  @exception_keys ~w(type value stacktrace cause)
  @frame_keys ~w(file function lineno colno in_app pre_context context_line post_context)
  @breadcrumb_keys ~w(category message level ts data)
  @user_keys ~w(id email)
  @levels ~w(fatal error warning info)

  setup do
    config = Config.new(key: "alp_p_test_key_123", environment: "test", release: "1.0.0")
    {:ok, config: config}
  end

  test "an exception item only uses server-accepted keys", %{config: config} do
    item =
      Envelope.exception_item("err_test", %RuntimeError{message: "boom"},
        environment: config.environment,
        release: config.release,
        stacktrace: [{__MODULE__, :test, 0, [file: ~c"test.ex", line: 1]}],
        tags: %{"a" => "b"},
        contexts: %{"extra" => %{}},
        breadcrumbs: [
          %{"category" => "nav", "message" => "clicked", "level" => "info", "ts" => "now"}
        ],
        user: %{"id" => "u1", "email" => "u@example.com"},
        fingerprint: ["a"]
      )
      |> json_roundtrip()

    assert_subset_of(item, @item_keys)
    assert byte_size(item["id"]) in 4..64
    assert item["level"] in @levels
    assert item["type"] == "exception"
    assert_subset_of(item["exception"], @exception_keys)

    for frame <- get_in(item, ["exception", "stacktrace", "frames"]) || [] do
      assert_subset_of(frame, @frame_keys)
    end

    for breadcrumb <- item["breadcrumbs"] || [] do
      assert_subset_of(breadcrumb, @breadcrumb_keys)
    end

    assert_subset_of(item["user"], @user_keys)
  end

  test "a message item only uses server-accepted keys", %{config: config} do
    item =
      Envelope.message_item("err_test", "hello", "warning",
        environment: config.environment,
        release: config.release
      )
      |> json_roundtrip()

    assert_subset_of(item, @item_keys)
    assert item["type"] == "message"
    assert item["level"] in @levels
  end

  test "the envelope header only uses server-accepted keys", %{config: config} do
    envelope = Envelope.build(config, []) |> json_roundtrip()

    assert_subset_of(envelope, ~w(header items))
    assert_subset_of(envelope["header"], @header_keys)
    assert_subset_of(envelope["header"]["sdk"], @sdk_keys)
  end

  defp json_roundtrip(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp assert_subset_of(nil, _allowed), do: :ok

  defp assert_subset_of(map, allowed) when is_map(map) do
    extra = Map.keys(map) -- allowed
    assert extra == [], "unexpected key(s) the server parser would reject: #{inspect(extra)}"
  end
end
