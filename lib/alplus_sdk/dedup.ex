defmodule AlplusSDK.Dedup do
  @moduledoc """
  Pure dedup bookkeeping for `capture_exception/2`, mirroring the window and
  size bound of `packages/sdk/src/core/observe/dedup.ts`'s `resolveDedupId`
  so the same error captured twice within a short window reports once in
  every AL+ SDK.

  Deliberately kept as a plain data structure (a bounded map passed in and
  returned, not a process of its own): JS keys its dedup cache on error
  OBJECT IDENTITY via a `WeakMap` (falling back to a stringified value for
  non-object throws) because JS values genuinely have reference identity.
  Elixir exceptions are plain structs with no such identity -- two mentions
  of "the same error" are two structurally-equal terms, not two references
  to one object -- so this module always keys on a structural `signature/1`
  instead. The window (2s) and the bound on the value-keyed fallback (50
  entries) are copied byte-identical from `dedup.ts` even though the
  identity-keyed half of that file has no Elixir equivalent.

  The cache itself lives in `AlplusSDK.Client`'s `GenServer` state (a
  process already supervised by the host app) rather than a dedicated
  process of its own: JS's dedup is deliberately module-level, NOT part of
  `ObserveState`, so it survives `init()` being called again -- Elixir has
  no equivalent "reinitialize without restarting the process" operation
  (restarting the supervised `Client` already clears everything, dedup
  included), so tying it to the one process that already owns this SDK's
  live state avoids introducing a second, unsupervised, always-on process
  for a per-app cache this small.
  """

  @window_ms 2_000
  @value_cache_max 50

  @type key :: term()
  @type entry :: %{id: String.t(), expires_at: integer()}
  @type cache :: %{key() => entry()}

  @doc "The dedup window in milliseconds (byte-identical to `DEDUP_WINDOW_MS` in `dedup.ts`)."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc """
  A structural signature for `error`, used as the dedup cache key. An
  `Exception.t()` signs on its struct module + rendered message; anything
  else signs on `inspect/1` -- both are just string/term equality, matching
  what `stringifyPrimitive` does in `dedup.ts` for a non-object throw.
  """
  @spec signature(term()) :: key()
  def signature(%_{__exception__: true} = exception) do
    {exception.__struct__, safe_message(exception)}
  end

  def signature(other), do: {:term, inspect(other)}

  defp safe_message(exception) do
    Exception.message(exception)
  rescue
    _ -> nil
  end

  @doc """
  Resolves `key` against `cache` at time `now` (`System.system_time(:millisecond)`):
  returns `{:duplicate, previous_id}` if `key` was signed within the window,
  else registers `fresh_id` and returns `{:fresh, fresh_id}`. Always returns
  the (possibly pruned/bounded) cache to store back in the caller's state.
  """
  @spec resolve(cache(), key(), String.t(), integer()) ::
          {{:fresh, String.t()} | {:duplicate, String.t()}, cache()}
  def resolve(cache, key, fresh_id, now) when is_map(cache) do
    cache = prune_expired(cache, now)

    case Map.get(cache, key) do
      %{id: id, expires_at: expires_at} when expires_at > now ->
        {{:duplicate, id}, cache}

      _ ->
        cache =
          cache
          |> evict_oldest_if_full(@value_cache_max)
          |> Map.put(key, %{id: fresh_id, expires_at: now + @window_ms})

        {{:fresh, fresh_id}, cache}
    end
  end

  defp prune_expired(cache, now) do
    cache
    |> Enum.reject(fn {_key, %{expires_at: expires_at}} -> expires_at <= now end)
    |> Map.new()
  end

  defp evict_oldest_if_full(cache, max) when map_size(cache) < max, do: cache

  defp evict_oldest_if_full(cache, _max) do
    {oldest_key, _entry} = Enum.min_by(cache, fn {_key, %{expires_at: e}} -> e end)
    Map.delete(cache, oldest_key)
  end
end
