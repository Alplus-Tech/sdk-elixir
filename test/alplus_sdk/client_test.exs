defmodule AlplusSDK.ClientTest do
  use ExUnit.Case, async: true

  alias AlplusSDK.Client

  defp start_client(opts) do
    name = :"client_bound_test_#{System.unique_integer([:positive])}"

    default_opts = [
      name: name,
      key: "alp_p_test_key_123",
      # Deliberately unreachable: this test never wants a real flush --
      # `flush_interval_ms: 0` and a huge `batch_max_items` keep every
      # enqueued item sitting in the queue so its length is deterministic.
      base_url: "http://localhost:1",
      flush_interval_ms: 0,
      batch_max_items: 1_000_000,
      batch_max_bytes: 1_000_000_000,
      integrations: []
    ]

    start_supervised!({Client, Keyword.merge(default_opts, opts)})
    name
  end

  test "the session queue is bounded: the newest item is dropped once session_queue_max_items is reached (issue #12 fix)" do
    name = start_client(session_queue_max_items: 3)

    for n <- 1..10, do: Client.enqueue_session(name, %{id: "ses_#{n}"})

    # `Client.config/1` is a `GenServer.call`, sent after every cast above:
    # a plain `GenServer`'s message loop processes its mailbox strictly in
    # arrival order, so this round-trip guarantees every prior cast has
    # already been handled before the `:sys.get_state/1` inspection below
    # (which, unlike a normal call, is a system message that could
    # otherwise race ahead of still-pending casts).
    _config = Client.config(name)

    state = :sys.get_state(name)
    assert length(state.session_queue) == 3
  end

  test "the error queue is unaffected by the session queue's bound" do
    name = start_client(session_queue_max_items: 1)

    Client.enqueue_session(name, %{id: "ses_1"})
    Client.enqueue_session(name, %{id: "ses_2"})
    Client.enqueue(name, %{id: "err_1"})
    Client.enqueue(name, %{id: "err_2"})

    _config = Client.config(name)
    state = :sys.get_state(name)

    assert length(state.session_queue) == 1
    assert length(state.queue) == 2
  end

  test "session_queue_max_items defaults to a positive bound" do
    assert AlplusSDK.Config.new(key: "alp_p_test").session_queue_max_items > 0
  end
end
