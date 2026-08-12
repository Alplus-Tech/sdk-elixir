defmodule AlplusSDK.Envelope do
  @moduledoc """
  Builds the `POST /e/errors` wire envelope and individual items, mirroring
  `packages/sdk/src/core/observe/{envelope,client}.ts` and validated against
  `Alplus.Observe.ErrorEnvelope` (the server parser) so a captured event is
  never dropped as malformed by the caps below.

  `Jason.encode!/1` on a `nil` map value omits the key by default only if we
  build maps without the key at all -- every builder here uses `compact/1`
  to drop `nil` values before encoding, matching the server's `exact_keys?`
  check (an unexpected `null`-valued key is still a present key).
  """

  alias AlplusSDK.Config

  @sdk_name "alplus-elixir"
  @sdk_version Mix.Project.config()[:version] || "0.1.0"

  # Mirrors `packages/sdk/src/core/observe/envelope.ts`'s `MAX_*` constants
  # and `sdks/ruby/lib/alplus/envelope.rb`'s copies of the same -- all three
  # SDKs must cap identically so a payload trimmed by one still groups the
  # same as one trimmed by another.
  @max_message_chars 4_096
  @max_exception_value_chars 4_096
  @max_tags_chars 4_096
  @max_context_chars 8_192
  @max_stack_trace_chars 16_384
  @server_max_breadcrumbs 100
  @max_breadcrumb_message_chars 2_048
  @max_breadcrumb_category_chars 128

  def sdk_name, do: @sdk_name
  def sdk_version, do: @sdk_version

  @doc "Wraps queued items in the envelope `header`/`items` shape."
  @spec build(Config.t(), [map()]) :: map()
  def build(%Config{} = config, items) when is_list(items) do
    %{
      header: %{
        key: config.key,
        sdk: %{name: @sdk_name, version: @sdk_version, platform: "elixir"},
        sent_at: DateTime.utc_now() |> DateTime.to_iso8601()
      },
      items: items
    }
  end

  @doc """
  Builds an `"exception"` item. `stacktrace` is an Elixir stacktrace
  (`[{module, fun, arity, location}]` or already-built wire frames);
  `in_app_otp_apps` marks a frame `in_app: true` when its module belongs to
  one of the host's own OTP applications.
  """
  @spec exception_item(String.t(), Exception.t() | term(), keyword()) :: map()
  def exception_item(id, exception, opts \\ []) do
    {type, value} = exception_type_and_value(exception)
    stacktrace = Keyword.get(opts, :stacktrace, [])
    in_app_otp_apps = Keyword.get(opts, :in_app_otp_apps, [])
    frames = build_frames(stacktrace, in_app_otp_apps)

    %{
      id: id,
      type: "exception",
      timestamp: iso_now(),
      level: Keyword.get(opts, :level, "error"),
      release: Keyword.get(opts, :release),
      environment: Keyword.get(opts, :environment),
      exception:
        compact(%{
          type: type,
          value: cap_text(value, @max_exception_value_chars),
          stacktrace: if(frames != [], do: %{frames: cap_frames(frames, @max_stack_trace_chars)})
        }),
      mechanism: Keyword.get(opts, :mechanism, "generic")
    }
    |> put_scope(opts)
    |> compact()
  end

  @doc "Builds a `\"message\"` item."
  @spec message_item(String.t(), String.t(), String.t(), keyword()) :: map()
  def message_item(id, message, level, opts \\ []) do
    %{
      id: id,
      type: "message",
      timestamp: iso_now(),
      level: level,
      release: Keyword.get(opts, :release),
      environment: Keyword.get(opts, :environment),
      message: cap_text(message, @max_message_chars),
      mechanism: Keyword.get(opts, :mechanism, "generic")
    }
    |> put_scope(opts)
    |> compact()
  end

  @doc """
  Builds a `POST /e/sessions` wire item (issue #12) from an
  `AlplusSDK.Session.t()`. Carries no PII: `session.id` is opaque and used
  server-side only for in-window ingest dedup, then discarded (never stored
  raw) -- matching `Alplus.Observe.SessionEnvelope`, the server parser.
  """
  @spec session_item(AlplusSDK.Session.t(), keyword()) :: map()
  def session_item(%{id: id, status: status, started_at: started_at}, opts \\ []) do
    %{
      id: id,
      status: Atom.to_string(status),
      started_at: DateTime.to_iso8601(started_at),
      duration_ms: DateTime.diff(DateTime.utc_now(), started_at, :millisecond),
      release: Keyword.get(opts, :release),
      environment: Keyword.get(opts, :environment)
    }
    |> compact()
  end

  @doc "Serialized byte size of an already-built item, used for batch-size accounting."
  @spec byte_size_of(map()) :: non_neg_integer()
  def byte_size_of(item), do: item |> Jason.encode!() |> byte_size()

  defp exception_type_and_value(%_{__exception__: true} = exception) do
    {exception.__struct__ |> Module.split() |> Enum.join("."), Exception.message(exception)}
  end

  defp exception_type_and_value(other) do
    {"Error", inspect(other)}
  end

  defp build_frames(stacktrace, in_app_otp_apps) when is_list(stacktrace) do
    stacktrace
    |> Enum.map(&build_frame(&1, in_app_otp_apps))
    |> Enum.reject(&is_nil/1)
  end

  defp build_frames(_, _), do: []

  defp build_frame({module, function, arity, location}, in_app_otp_apps) when is_list(location) do
    compact(%{
      function: format_mfa(module, function, arity),
      file: location[:file] && to_string(location[:file]),
      lineno: location[:line],
      in_app: in_app?(module, in_app_otp_apps)
    })
  end

  defp build_frame(%{} = wire_frame, _in_app_otp_apps), do: wire_frame

  # A malformed stack entry (unexpected shape from a caller-supplied
  # `:stacktrace` option) skips just this one frame rather than raising and
  # dropping the whole event -- `capture_exception/2` must stay fail-safe
  # even when handed a garbage stacktrace.
  defp build_frame(_unrecognized, _in_app_otp_apps), do: nil

  defp format_mfa(module, function, arity) when is_atom(module) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  defp format_mfa(module, function, arity), do: "#{module}.#{function}/#{arity}"

  defp in_app?(_module, []), do: nil

  defp in_app?(module, in_app_otp_apps) do
    Application.get_application(module) in in_app_otp_apps
  end

  defp put_scope(item, opts) do
    contexts = merge_extra_context(Keyword.get(opts, :contexts), Keyword.get(opts, :context))

    item
    |> Map.put(:tags, cap_tags(Keyword.get(opts, :tags)))
    |> Map.put(:contexts, cap_context(contexts, @max_context_chars))
    |> Map.put(
      :breadcrumbs,
      cap_breadcrumbs(Keyword.get(opts, :breadcrumbs), @server_max_breadcrumbs)
    )
    |> Map.put(:fingerprint, Keyword.get(opts, :fingerprint))
    |> Map.put(:user, normalize_user(Keyword.get(opts, :user)))
  end

  @doc """
  Normalizes any `:user` value (per-call opt or `AlplusSDK.Scope` ambient
  user) to the wire `user` shape: string keys `"id"`/`"email"` only, each
  value stringified. The server's `user_keys` allowlist (`~w(id email)`)
  rejects the WHOLE item on an unrecognized key, and its `valid_user?`
  check requires a binary `id`/`email` -- a normal Phoenix integer PK
  (`%{id: user.id}`) or an atom-keyed map would otherwise silently drop the
  event. Accepts atom or string keys on the way in; drops anything else,
  drops `nil` values, and drops down to `nil` (omitted from the wire item)
  if nothing recognized was present.
  """
  @spec normalize_user(map() | nil) :: map() | nil
  def normalize_user(nil), do: nil

  def normalize_user(user) when is_map(user) do
    %{}
    |> maybe_put_user_field("id", fetch_user_field(user, :id))
    |> maybe_put_user_field("email", fetch_user_field(user, :email))
    |> case do
      empty when map_size(empty) == 0 -> nil
      normalized -> normalized
    end
  end

  def normalize_user(_other), do: nil

  defp fetch_user_field(user, key) do
    case Map.fetch(user, key) do
      {:ok, value} -> value
      :error -> Map.get(user, Atom.to_string(key))
    end
  end

  defp maybe_put_user_field(map, _key, nil), do: map
  defp maybe_put_user_field(map, key, value), do: Map.put(map, key, to_string(value))

  # Folds the `:context` convenience option (arbitrary structured data local
  # to one capture) into `contexts["extra"]`, mirroring JS's `context` ->
  # `contexts.extra` fold (`client.ts`'s `mergeContext`) and matching the
  # server's `contexts` wire shape rather than shipping a second top-level
  # `context` key the parser doesn't recognize.
  defp merge_extra_context(nil, nil), do: nil
  defp merge_extra_context(contexts, nil), do: contexts
  defp merge_extra_context(nil, extra), do: %{"extra" => extra}

  defp merge_extra_context(contexts, extra) when is_map(contexts),
    do: Map.put(contexts, "extra", extra)

  defp merge_extra_context(contexts, _extra), do: contexts

  defp cap_tags(nil), do: nil
  defp cap_tags(tags) when map_size(tags) == 0, do: nil

  defp cap_tags(tags) do
    if byte_size(Jason.encode!(tags)) <= @max_tags_chars, do: tags, else: nil
  end

  # Caps a JSON-ish context map by its serialized size. A value whose
  # serialization exceeds `max_chars` is REPLACED by a small truncation
  # marker rather than cut mid-string (mirrors JS `capContext` /
  # Ruby `cap_context`): a partial JSON string is unparseable, which is
  # worse than a shorter one.
  defp cap_context(nil, _max_chars), do: nil

  defp cap_context(context, max_chars) when is_map(context) do
    serialized = Jason.encode!(context)

    if byte_size(serialized) <= max_chars do
      context
    else
      %{_truncated: true, _original_chars: byte_size(serialized)}
    end
  end

  defp cap_context(other, _max_chars), do: other

  # Drops trailing frames until the serialized array fits `max_chars`,
  # mirroring JS `capFrames` / Ruby `cap_frames` -- the top (earliest, most
  # relevant) frames are kept, later/outer frames are dropped first.
  defp cap_frames([], _max_chars), do: []

  defp cap_frames(frames, max_chars) when is_list(frames) do
    if byte_size(Jason.encode!(frames)) <= max_chars do
      frames
    else
      frames |> List.delete_at(-1) |> cap_frames(max_chars)
    end
  end

  # Caps breadcrumb count to the server's own ceiling, keeping the most
  # recent entries (mirrors JS `merged.breadcrumbs.slice(-SERVER_MAX_BREADCRUMBS)`),
  # and caps each entry's `category`/`message` length.
  defp cap_breadcrumbs(nil, _max_count), do: nil

  defp cap_breadcrumbs(breadcrumbs, max_count) when is_list(breadcrumbs) do
    breadcrumbs
    |> Enum.map(&cap_breadcrumb_fields/1)
    |> Enum.take(-max_count)
  end

  defp cap_breadcrumbs(other, _max_count), do: other

  defp cap_breadcrumb_fields(breadcrumb) when is_map(breadcrumb) do
    breadcrumb
    |> cap_field_if_present(["category", :category], @max_breadcrumb_category_chars)
    |> cap_field_if_present(["message", :message], @max_breadcrumb_message_chars)
  end

  defp cap_breadcrumb_fields(other), do: other

  defp cap_field_if_present(map, keys, max) do
    Enum.reduce(keys, map, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when is_binary(value) -> Map.put(acc, key, cap_text(value, max))
        _ -> acc
      end
    end)
  end

  defp cap_text(nil, _max), do: nil
  defp cap_text(text, max) when is_binary(text), do: String.slice(text, 0, max)

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
