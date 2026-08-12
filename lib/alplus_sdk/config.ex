defmodule AlplusSDK.Config do
  @moduledoc """
  Resolves `AlplusSDK.Client` options: explicit `start_link/1` opts win over
  `Application.get_env(:alplus_sdk, ...)`, which wins over the documented
  default.

  The ingest key is read once at start (never logged: `inspect/1` on
  `%AlplusSDK.Config{}` redacts it, and no code path formats it into a log
  line).
  """

  @enforce_keys [:key]
  defstruct key: nil,
            environment: "production",
            release: nil,
            base_url: "https://ingest.alplus.dev",
            receive_timeout: 5_000,
            enabled?: true,
            batch_max_items: 10,
            batch_max_bytes: 64 * 1024,
            flush_interval_ms: 5_000,
            in_app_otp_apps: [],
            debug: false

  @type t :: %__MODULE__{
          key: String.t(),
          environment: String.t(),
          release: String.t() | nil,
          base_url: String.t(),
          receive_timeout: pos_integer(),
          enabled?: boolean(),
          batch_max_items: pos_integer(),
          batch_max_bytes: pos_integer(),
          flush_interval_ms: non_neg_integer(),
          in_app_otp_apps: [atom()],
          debug: boolean()
        }

  @max_envelope_bytes 1_048_576
  def max_envelope_bytes, do: @max_envelope_bytes

  @doc """
  Builds a `Config` from `start_link/1` opts, falling back to
  `Application.get_env(:alplus_sdk, :config, [])`. Raises `ArgumentError` if
  no `:key` is configured anywhere -- a missing ingest key is a startup
  error, not a silently-disabled SDK.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    app_env = Application.get_env(:alplus_sdk, :config, [])
    merged = Keyword.merge(app_env, opts)

    key =
      Keyword.get(merged, :key) || raise ArgumentError, "AlplusSDK requires a :key (ingest key)"

    struct(__MODULE__, Keyword.put(merged, :key, key))
  end

  defimpl Inspect do
    def inspect(config, opts) do
      redacted = config |> Map.put(:key, "[REDACTED]") |> Map.from_struct()

      Inspect.Algebra.concat([
        "#AlplusSDK.Config<",
        Kernel.inspect(redacted, Map.to_list(opts)),
        ">"
      ])
    end
  end
end
