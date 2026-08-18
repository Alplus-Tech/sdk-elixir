defmodule AlplusSDK.Scope do
  @moduledoc false

  @max_breadcrumbs 100
  @pdict_key :__alplus_sdk_scope__

  defstruct user: nil, tags: %{}, contexts: %{}, breadcrumbs: []

  @type t :: %__MODULE__{
          user: map() | nil,
          tags: %{optional(String.t()) => String.t()},
          contexts: %{optional(String.t()) => map()},
          breadcrumbs: [map()]
        }

  @doc """
  Sets the ambient user (`%{id: ..., email: ...}`, atom or string keyed).
  Normalized through `AlplusSDK.Envelope.normalize_user/1` -- both keys are
  stringified (a normal Phoenix integer PK is a common `id`, and the
  server's `valid_user?` requires a binary) -- so a caller never has to
  remember to `to_string/1` it themselves. `nil` (or any non-map) clears
  the ambient user.
  """
  @spec set_user(map() | nil) :: :ok
  def set_user(user) do
    update(fn scope -> %{scope | user: AlplusSDK.Envelope.normalize_user(user)} end)
  end

  @doc "Sets one ambient tag. Both `key` and `value` are stringified, matching the wire `tags` shape (string -> string)."
  @spec set_tag(term(), term()) :: :ok
  def set_tag(key, value) do
    update(fn scope -> %{scope | tags: Map.put(scope.tags, to_string(key), to_string(value))} end)
  end

  @doc "Sets one named ambient context (folds into the event's `contexts.<name>` on capture)."
  @spec set_context(term(), map()) :: :ok
  def set_context(name, data) when is_map(data) do
    update(fn scope -> %{scope | contexts: Map.put(scope.contexts, to_string(name), data)} end)
  end

  def set_context(_name, _invalid), do: :ok

  @doc """
  Appends one breadcrumb to the ambient trail. The trail is a bounded ring
  buffer (cap `#{@max_breadcrumbs}`, the server's own `SERVER_MAX_BREADCRUMBS`
  ceiling): the oldest entry is dropped once the cap is exceeded.
  """
  @spec add_breadcrumb(map()) :: :ok
  def add_breadcrumb(breadcrumb) when is_map(breadcrumb) do
    update(fn scope ->
      breadcrumbs = (scope.breadcrumbs ++ [breadcrumb]) |> Enum.take(-@max_breadcrumbs)
      %{scope | breadcrumbs: breadcrumbs}
    end)
  end

  def add_breadcrumb(_invalid), do: :ok

  @doc "Returns the current process's ambient scope (an empty `%AlplusSDK.Scope{}` if nothing was set)."
  @spec current() :: t()
  def current, do: Process.get(@pdict_key) || %__MODULE__{}

  @doc "Clears the current process's ambient scope. Called by `AlplusSDK.Plug` at the start of every request."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  defp update(fun) do
    Process.put(@pdict_key, fun.(current()))
    :ok
  rescue
    _ -> :ok
  end
end
