defmodule AlplusSDK.Scope do
  @moduledoc """
  Request-scoped ambient scope: the server analog of the JS SDK's
  `withScope`/browser scope (`packages/sdk/src/core/observe/scope.ts`),
  adapted to a process-per-request server (Plug/Phoenix/Bandit/Cowboy each
  give one request its own Erlang process) instead of a browser tab or a
  Node `AsyncLocalStorage` context.

  State lives in the calling process's dictionary, not a shared process:
  `Process.get/2`/`Process.put/2` are the correct tool here, not a
  `GenServer` or `ETS` table, because this state is scoped to exactly ONE
  process (the request) and must never leak to a concurrent request -- a
  shared process would need its own per-request key anyway, which is just
  the process dictionary with extra steps.

  Set once near the top of a request (typically from your own auth plug,
  after `AlplusSDK.Plug` has reset any leftover state):

      defmodule MyAppWeb.AlplusScopePlug do
        def init(opts), do: opts

        def call(conn, _opts) do
          if user = conn.assigns[:current_user] do
            AlplusSDK.Scope.set_user(%{id: to_string(user.id), email: user.email})
          end

          AlplusSDK.Scope.set_tag("org_id", conn.assigns.current_org_id)
          conn
        end
      end

      plug AlplusSDK.Plug
      plug MyAppWeb.AlplusScopePlug

  Every `AlplusSDK.capture_exception/2` and `AlplusSDK.capture_message/3`
  call in that process picks up the ambient user/tags/contexts/breadcrumbs
  automatically; an explicit `:user`/`:tags`/`:contexts`/`:breadcrumbs`
  option on the capture call itself wins over the ambient value on a
  per-key basis (an explicit `user: nil` clears the ambient user for that
  one capture), mirroring `mergeScope` in `scope.ts`.

  Every function here is fail-safe: a bad argument is swallowed rather than
  raised into the caller, consistent with the rest of this package.
  """

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
