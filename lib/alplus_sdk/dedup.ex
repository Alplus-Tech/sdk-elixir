defmodule AlplusSDK.Dedup do
  @moduledoc false

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

  defp safe_message(%module{} = exception) do
    module.message(exception)
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
