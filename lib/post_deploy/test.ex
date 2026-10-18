defmodule PostDeploy.Test do
  @moduledoc """
  In-memory recorder for host tests and the product ingest e2e path.

  Start the client with `test: true`. Capture as usual, then `flush/1`
  and read the recorded bodies. Nothing hits the network.

      start_supervised!({PostDeploy, key: "alp_test", test: true})
      PostDeploy.capture_exception(%RuntimeError{message: "boom"})
      PostDeploy.flush()
      [item] = PostDeploy.Test.events()
  """

  @doc false
  def record(name, body) when is_binary(body) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      Map.update(state, name, [body], &(&1 ++ [body]))
    end)

    :ok
  end

  @doc "Decoded Observe items recorded for `name` (default `PostDeploy.Client`)."
  @spec events(GenServer.name()) :: [map()]
  def events(name \\ PostDeploy.Client) do
    raw(name)
    |> Enum.flat_map(&items_of/1)
  end

  @doc """
  Encoded envelope bodies recorded for `name` (default `PostDeploy.Client`).

  The product e2e test POSTs these bytes to the real ingest route.
  """
  @spec raw(GenServer.name()) :: [binary()]
  def raw(name \\ PostDeploy.Client) do
    ensure_started()
    Agent.get(__MODULE__, &Map.get(&1, name, []))
  end

  @doc "Drops recorded envelopes for `name` (default `PostDeploy.Client`)."
  @spec reset!(GenServer.name()) :: :ok
  def reset!(name \\ PostDeploy.Client) do
    ensure_started()
    PostDeploy.Client.reset_dedup(name)

    Agent.update(__MODULE__, &Map.delete(&1, name))
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
