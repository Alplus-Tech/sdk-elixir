defmodule AlplusSDK.Config do
  @moduledoc """
  Resolves `AlplusSDK.Client` options: explicit `start_link/1` opts win over
  `Application.get_env(:alplus_sdk, ...)`, which wins over an `ALPLUS_*` env
  var, which wins over the documented default -- the same `ALPLUS_KEY` /
  `ALPLUS_ENDPOINT` / `ALPLUS_ENVIRONMENT` / `ALPLUS_RELEASE` convention the
  Ruby SDK already reads (`sdks/ruby/lib/alplus/configuration.rb`), so a
  process that sets these env vars needs no explicit `AlplusSDK.Config` at
  all. The JS SDK deliberately leaves this to the host instead (no bundler
  has one true env-var convention); server-side Elixir/Ruby processes do.

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
            sample_rate: 1.0,
            debug: false,
            session_queue_max_items: 1_000

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
          sample_rate: float(),
          debug: boolean(),
          session_queue_max_items: pos_integer()
        }

  @max_envelope_bytes 1_048_576
  def max_envelope_bytes, do: @max_envelope_bytes

  @default_base_url "https://ingest.alplus.dev"
  @default_environment "production"

  @doc """
  Builds a `Config` from `start_link/1` opts, falling back in order to
  `Application.get_env(:alplus_sdk, :config, [])`, then the matching
  `ALPLUS_*` env var, then the documented default. Raises `ArgumentError` if
  no `:key` is configured anywhere -- a missing ingest key is a startup
  error, not a silently-disabled SDK.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    app_env = Application.get_env(:alplus_sdk, :config, [])
    merged = Keyword.merge(app_env, opts)

    key =
      Keyword.get(merged, :key) || System.get_env("ALPLUS_KEY") ||
        raise ArgumentError, "AlplusSDK requires a :key (ingest key) or ALPLUS_KEY env var"

    environment =
      Keyword.get(merged, :environment) || System.get_env("ALPLUS_ENVIRONMENT") ||
        @default_environment

    release = Keyword.get(merged, :release) || System.get_env("ALPLUS_RELEASE")

    base_url =
      Keyword.get(merged, :base_url) || System.get_env("ALPLUS_ENDPOINT") || @default_base_url

    merged =
      merged
      |> Keyword.put(:key, key)
      |> Keyword.put(:environment, environment)
      |> Keyword.put(:release, release)
      |> Keyword.put(:base_url, base_url)

    struct(__MODULE__, merged)
  end

  @doc """
  Whether a capture should be sent, given `config.sample_rate` (default
  `1.0`, i.e. always). Mirrors `sdks/ruby/lib/alplus/configuration.rb`'s
  `sampled?` byte-for-byte: a rate `>= 1.0` always samples (skips the RNG
  call entirely so a default config never touches `:rand`), otherwise a
  uniform draw decides.
  """
  @spec sampled?(t()) :: boolean()
  def sampled?(%__MODULE__{sample_rate: rate}) when rate >= 1.0, do: true
  def sampled?(%__MODULE__{sample_rate: rate}), do: :rand.uniform() < rate

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
