defmodule AlplusSDK.Config do
  @moduledoc false

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
            # Lines of source before/after each in_app frame. `0` disables.
            # Matches Ruby `Configuration#context_lines` (default 3).
            context_lines: 3,
            sample_rate: 1.0,
            debug: false,
            session_queue_max_items: 1_000,
            # Post-error log window in ms (issue #47): an exception item
            # lingers in the client so Logger lines the erroring process
            # writes just afterwards join its breadcrumb timeline, marked
            # `after_error`. `0` disables; `flush/2` seals immediately.
            post_error_log_window_ms: 2_000,
            before_send: nil,
            test?: false

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
          context_lines: non_neg_integer(),
          sample_rate: float(),
          debug: boolean(),
          session_queue_max_items: pos_integer(),
          post_error_log_window_ms: non_neg_integer(),
          before_send: (map() -> map() | nil) | nil,
          test?: boolean()
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

    {test?, merged} = Keyword.pop(merged, :test, false)
    {test_flag, merged} = Keyword.pop(merged, :test?, false)
    test? = test? || test_flag

    {before_send, merged} = Keyword.pop(merged, :before_send)
    {_integrations, merged} = Keyword.pop(merged, :integrations)
    {_name, merged} = Keyword.pop(merged, :name)

    enabled? = Keyword.get(merged, :enabled?, true)

    key =
      Keyword.get(merged, :key) || System.get_env("ALPLUS_KEY") ||
        if enabled? do
          raise ArgumentError, "AlplusSDK requires a :key (ingest key) or ALPLUS_KEY env var"
        else
          ""
        end

    environment =
      Keyword.get(merged, :environment) || System.get_env("ALPLUS_ENVIRONMENT") ||
        @default_environment

    release = Keyword.get(merged, :release) || System.get_env("ALPLUS_RELEASE")

    base_url =
      Keyword.get(merged, :base_url) || System.get_env("ALPLUS_ENDPOINT") || @default_base_url

    window = Keyword.get(merged, :post_error_log_window_ms)
    window = if is_nil(window) and test?, do: 0, else: window

    merged =
      merged
      |> Keyword.put(:key, key)
      |> Keyword.put(:environment, environment)
      |> Keyword.put(:release, release)
      |> Keyword.put(:base_url, base_url)
      |> Keyword.put(:before_send, before_send)
      |> Keyword.put(:test?, test?)
      |> then(fn merged ->
        if is_nil(window),
          do: merged,
          else: Keyword.put(merged, :post_error_log_window_ms, window)
      end)

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
