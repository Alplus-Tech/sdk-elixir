defmodule AlplusSDK.Test do
  @moduledoc """
  In-memory recorder for host tests and the product ingest e2e path.

  Start the client with `test: true`. Capture as usual, then `flush/1`
  and read the recorded bodies. Nothing hits the network.

      start_supervised!({AlplusSDK, key: "alp_test", test: true})
      AlplusSDK.capture_exception(%RuntimeError{message: "boom"})
      AlplusSDK.flush()
      [item] = AlplusSDK.Test.events()
  """

  @doc false
  def record(name, kind, body) when kind in [:errors, :sessions] and is_binary(body) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      Map.update(state, {name, kind}, [body], &(&1 ++ [body]))
    end)

    :ok
  end

  @doc "Decoded Observe items recorded for `name` (default `AlplusSDK.Client`)."
  @spec events(GenServer.name()) :: [map()]
  def events(name \\ AlplusSDK.Client) do
    raw(name, :errors)
    |> Enum.flat_map(&items_of/1)
  end

  @doc "Decoded session items recorded for `name` (default `AlplusSDK.Client`)."
  @spec sessions(GenServer.name()) :: [map()]
  def sessions(name \\ AlplusSDK.Client) do
    raw(name, :sessions)
    |> Enum.flat_map(&items_of/1)
  end

  @doc """
  Encoded envelope bodies for `kind` (`:errors` or `:sessions`).

  The product e2e test POSTs these bytes to the real ingest route.
  """
  @spec raw(GenServer.name(), :errors | :sessions) :: [binary()]
  def raw(kind) when kind in [:errors, :sessions], do: raw(AlplusSDK.Client, kind)

  def raw(name, kind) when kind in [:errors, :sessions] do
    ensure_started()
    Agent.get(__MODULE__, &Map.get(&1, {name, kind}, []))
  end

  @doc "Drops recorded envelopes for `name` (default `AlplusSDK.Client`)."
  @spec reset!(GenServer.name()) :: :ok
  def reset!(name \\ AlplusSDK.Client) do
    ensure_started()
    AlplusSDK.Client.reset_dedup(name)

    Agent.update(__MODULE__, fn state ->
      state
      |> Map.delete({name, :errors})
      |> Map.delete({name, :sessions})
    end)
  end

  defp items_of(body) do
    case Jason.decode(body) do
      {:ok, %{"items" => items}} when is_list(items) -> items
      _ -> []
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_recorder()
      _pid -> :ok
    end
  end

  @doc false
  def start_recorder do
    case Agent.start_link(fn -> %{} end, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
