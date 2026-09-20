defmodule PostDeploy.Session do
  @moduledoc false

  @pdict_key :__postdeploy_sdk_session__

  @type status :: :healthy | :errored | :crashed

  @type t :: %{
          id: String.t(),
          status: status()
        }

  @doc "Starts a fresh session for the current process, discarding any previous one."
  @spec start() :: t()
  def start do
    session = %{
      id: PostDeploy.Id.generate_session_id(),
      status: :healthy
    }

    Process.put(@pdict_key, session)
    session
  end

  @doc "The current process's session, or `nil` if none was started."
  @spec current() :: t() | nil
  def current, do: Process.get(@pdict_key)

  @doc "Marks the current session `:errored`, unless it is already `:crashed`."
  @spec mark_errored() :: :ok
  def mark_errored, do: bump(:errored)

  @doc "Marks the current session `:crashed`. Terminal: never downgraded within the same request."
  @spec mark_crashed() :: :ok
  def mark_crashed, do: bump(:crashed)

  @doc "Clears the current process's session. Called by `PostDeploy.Plug` at the start of every request."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  defp bump(new_status) do
    case current() do
      nil ->
        :ok

      session ->
        if severity(new_status) > severity(session.status) do
          Process.put(@pdict_key, %{session | status: new_status})
        end

        :ok
    end
  rescue
    _ -> :ok
  end

  defp severity(:healthy), do: 0
  defp severity(:errored), do: 1
  defp severity(:crashed), do: 2
end
