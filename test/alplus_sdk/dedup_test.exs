defmodule AlplusSDK.DedupTest do
  @moduledoc """
  Pure unit tests for `AlplusSDK.Dedup`'s bookkeeping (no client, no
  network) -- the integration behavior (a duplicate `capture_exception/2`
  call returns the first id and is not re-queued) is covered by
  `AlplusSDKTest`.
  """

  use ExUnit.Case, async: true

  alias AlplusSDK.Dedup

  test "the same signature within the window returns the first id" do
    now = 1_000
    key = Dedup.signature(%RuntimeError{message: "boom"})

    {{:fresh, "id1"}, cache} = Dedup.resolve(%{}, key, "id1", now)
    {{:duplicate, "id1"}, _cache} = Dedup.resolve(cache, key, "id2", now + 100)
  end

  test "the same signature after the window expires reports fresh again" do
    now = 1_000
    key = Dedup.signature(%RuntimeError{message: "boom"})

    {{:fresh, "id1"}, cache} = Dedup.resolve(%{}, key, "id1", now)
    {{:fresh, "id2"}, _cache} = Dedup.resolve(cache, key, "id2", now + Dedup.window_ms() + 1)
  end

  test "different exception types/messages sign differently" do
    key_a = Dedup.signature(%RuntimeError{message: "boom"})
    key_b = Dedup.signature(%RuntimeError{message: "different message"})
    key_c = Dedup.signature(%ArgumentError{message: "boom"})

    assert key_a != key_b
    assert key_a != key_c
  end

  test "non-exception terms sign structurally, same value dedups" do
    now = 1_000
    key_a = Dedup.signature("a plain string error")
    key_b = Dedup.signature("a plain string error")
    key_c = Dedup.signature("a different string")

    assert key_a == key_b
    assert key_a != key_c

    {{:fresh, "id1"}, cache} = Dedup.resolve(%{}, key_a, "id1", now)
    {{:duplicate, "id1"}, _cache} = Dedup.resolve(cache, key_b, "id2", now + 1)
  end

  test "the value cache is bounded, evicting the oldest entry first" do
    now = 1_000
    max = 50

    cache =
      Enum.reduce(1..max, %{}, fn n, cache ->
        {{:fresh, _id}, cache} = Dedup.resolve(cache, {:n, n}, "id_#{n}", now + n)
        cache
      end)

    assert map_size(cache) == max

    {{:fresh, _}, cache} = Dedup.resolve(cache, {:n, max + 1}, "id_overflow", now + max + 1)

    assert map_size(cache) == max
    # The oldest entry (smallest expires_at, key {:n, 1}) was evicted to make room.
    refute Map.has_key?(cache, {:n, 1})
    assert Map.has_key?(cache, {:n, max + 1})
  end
end
