defmodule PostDeploy.Scrubber do
  @moduledoc false

  @filtered "[FILTERED]"
  @sensitive_key_parts ~w(password passwd secret token api_key apikey authorization cookie)
  @scrubbed_keys [
    :contexts,
    :tags,
    :user,
    :breadcrumbs,
    "contexts",
    "tags",
    "user",
    "breadcrumbs"
  ]

  @spec scrub(map()) :: map()
  def scrub(item) when is_map(item) do
    Enum.reduce(@scrubbed_keys, item, fn key, scrubbed ->
      case Map.fetch(scrubbed, key) do
        {:ok, value} -> Map.put(scrubbed, key, deep_scrub(value))
        :error -> scrubbed
      end
    end)
  end

  defp deep_scrub(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key), do: {key, @filtered}, else: {key, deep_scrub(nested)}
    end)
  end

  defp deep_scrub(value) when is_list(value), do: Enum.map(value, &deep_scrub/1)
  defp deep_scrub(value), do: value

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_key_parts, &String.contains?(normalized, &1))
  end
end
