defmodule AlplusSDK.Stack do
  @moduledoc false

  # Longest source line kept in `pre_context`/`context_line`/`post_context`.
  # A single absurdly long line (generated code) is truncated rather than
  # blowing up the envelope. Matches Ruby `Stack::MAX_SOURCE_LINE_CHARS`.
  @max_source_line_chars 500
  @max_cached_source_files 256
  @source_cache_table __MODULE__.SourceCache

  @doc """
  Builds wire frames from an Elixir stacktrace
  (`[{module, fun, arity_or_args, location}]`) or already-built wire maps.
  A malformed entry is skipped rather than raising.
  """
  @spec frames([tuple() | map()], [atom()], non_neg_integer()) :: [map()]
  def frames(stacktrace, in_app_otp_apps, context_lines)
      when is_list(stacktrace) and is_list(in_app_otp_apps) and is_integer(context_lines) do
    stacktrace
    |> Enum.map(&build_frame(&1, in_app_otp_apps, context_lines))
    |> Enum.reject(&is_nil/1)
  end

  def frames(_, _, _), do: []

  @doc """
  Renders `Mod.fun/arity`. When the stack entry carries the argument list
  (Elixir does this for a failed call such as `Map.fetch!/2`) the arity is
  `length(args)` — interpolating the list itself raises `ArgumentError`
  (`List.to_string` on a mixed list) and would drop the whole event.
  """
  @spec format_mfa(module() | term(), atom() | term(), non_neg_integer() | list()) :: String.t()
  def format_mfa(module, function, arity) when is_integer(arity) and arity >= 0 do
    "#{format_module(module)}.#{function}/#{arity}"
  end

  def format_mfa(module, function, args) when is_list(args) do
    format_mfa(module, function, length(args))
  end

  def format_mfa(module, function, _other) do
    "#{format_module(module)}.#{function}/?"
  end

  defp format_module(module) when is_atom(module), do: inspect(module)
  defp format_module(module), do: to_string(module)

  defp build_frame({module, function, arity, location}, in_app_otp_apps, context_lines)
       when is_list(location) do
    in_app = in_app?(module, in_app_otp_apps)
    file = location[:file] && to_string(location[:file])
    lineno = location[:line]

    frame =
      compact(%{
        function: format_mfa(module, function, arity),
        file: file,
        lineno: lineno,
        in_app: in_app
      })

    if in_app == true and context_lines > 0 do
      Map.merge(frame, source_context(file, lineno, context_lines))
    else
      frame
    end
  end

  defp build_frame(%{} = wire_frame, _in_app_otp_apps, _context_lines), do: wire_frame

  # A malformed stack entry (unexpected shape from a caller-supplied
  # `:stacktrace` option) skips just this one frame rather than raising and
  # dropping the whole event — `capture_exception/2` must stay fail-safe
  # even when handed a garbage stacktrace.
  defp build_frame(_unrecognized, _in_app_otp_apps, _context_lines), do: nil

  defp in_app?(_module, []), do: nil

  defp in_app?(module, in_app_otp_apps) do
    Application.get_application(module) in in_app_otp_apps
  end

  # Reads `context_lines` lines before/after `lineno` (1-indexed, as
  # stacktraces report it). Returns `%{}` (attaching nothing) for a
  # missing/unreadable file or an out-of-range line number.
  @doc false
  def source_context(file, lineno, context_lines)
      when is_binary(file) and is_integer(lineno) and is_integer(context_lines) and
             context_lines > 0 do
    path = resolve_source_path(file)

    with true <- is_binary(path),
         lines when is_list(lines) <- cached_source_lines(path),
         index = lineno - 1,
         true <- index >= 0 and index < length(lines) do
      start_index = max(index - context_lines, 0)
      end_index = min(index + context_lines, length(lines) - 1)

      %{
        pre_context:
          lines |> Enum.slice(start_index, index - start_index) |> Enum.map(&cap_source_line/1),
        context_line: cap_source_line(Enum.at(lines, index)),
        post_context:
          lines |> Enum.slice(index + 1, end_index - index) |> Enum.map(&cap_source_line/1)
      }
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  def source_context(_file, _lineno, _context_lines), do: %{}

  defp resolve_source_path(file) do
    if File.regular?(file), do: file
  end

  defp cached_source_lines(path) do
    table = source_cache_table()

    case :ets.lookup(table, path) do
      [{^path, lines}] ->
        lines

      [] ->
        lines = path |> File.read!() |> String.split("\n")
        :ets.insert(table, {path, lines})
        evict_if_full(table)
        lines
    end
  end

  defp source_cache_table do
    case :ets.whereis(@source_cache_table) do
      :undefined ->
        create_source_cache_table()

      tid ->
        tid
    end
  end

  @doc false
  def create_source_cache_table do
    :ets.new(@source_cache_table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    ArgumentError ->
      :ets.whereis(@source_cache_table)
  end

  defp evict_if_full(table) do
    if :ets.info(table, :size) > @max_cached_source_files do
      :ets.delete(table, :ets.first(table))
    end
  end

  defp cap_source_line(line) when is_binary(line) do
    line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")

    if String.length(line) > @max_source_line_chars do
      String.slice(line, 0, @max_source_line_chars)
    else
      line
    end
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
