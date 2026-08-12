defmodule AlplusSDK.Transport do
  @moduledoc """
  Wraps `Req` for the two requests this SDK makes (`POST /e/errors`,
  `POST /h/:token`) behind a project-owned module so no other module in
  this package calls `Req` directly.

  Retries transient failures with jittered exponential backoff, honoring a
  429's `Retry-After`, mirroring
  `packages/sdk/src/core/observe/transport.ts`'s `postJsonWithRetries`
  byte-identically (same default attempt count, backoff base/jitter, and
  `Retry-After` cap) so a transient ingest blip behaves the same across
  every AL+ SDK. A permanent 400/401/403/404 (malformed envelope, bad key,
  unrecognized route) is dropped without retrying -- retrying a request the
  server has already rejected as wrong cannot help.

  `AlplusSDK.heartbeat/3` overrides `:max_attempts` and
  `:honor_retry_after` (see that function's moduledoc): a heartbeat call is
  synchronous on the caller's thread, so its retry budget is deliberately
  smaller and never trusts a server-supplied `Retry-After` that could block
  a cron job for up to 30s.

  Every outcome (2xx, permanent 4xx, exhausted retries, timeout, connection
  error) is swallowed here: Observe ingest and Monitor heartbeats are
  best-effort telemetry, never allowed to raise into the host application
  that depends on this SDK. Retries run entirely off the request path: the
  caller of `post/2`/`request/3` already runs inside `AlplusSDK.Client`'s
  own flush task (`POST /e/errors`) or the caller's own process for a
  `heartbeat/2` call, never inside a `GenServer`'s main loop, so blocking
  between attempts cannot back up an unrelated mailbox.
  """

  require Logger

  alias AlplusSDK.Config

  @max_attempts 3
  @backoff_base_ms 500
  @backoff_jitter 0.5
  @max_retry_after_ms 30_000
  @permanent_statuses [400, 401, 403, 404]

  @typep retry_opts :: %{
           debug: boolean(),
           label: String.t(),
           max_attempts: pos_integer(),
           honor_retry_after: boolean(),
           sleep_fun: (non_neg_integer() -> term())
         }

  @doc "POSTs an already-encoded envelope body to `config.base_url <> \"/e/errors\"`. Always returns `:ok`; never raises."
  @spec post(Config.t(), String.t()) :: :ok
  def post(%Config{} = config, body) when is_binary(body) do
    url = String.trim_trailing(config.base_url, "/") <> "/e/errors"

    request(:post, url,
      body: body,
      headers: [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{config.key}"}
      ],
      receive_timeout: config.receive_timeout,
      debug: config.debug,
      debug_label: "Observe ingest"
    )
  end

  @doc "POSTs an already-encoded session-envelope body (issue #12) to `config.base_url <> \"/e/sessions\"`. Always returns `:ok`; never raises."
  @spec post_sessions(Config.t(), String.t()) :: :ok
  def post_sessions(%Config{} = config, body) when is_binary(body) do
    url = String.trim_trailing(config.base_url, "/") <> "/e/sessions"

    request(:post, url,
      body: body,
      headers: [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{config.key}"}
      ],
      receive_timeout: config.receive_timeout,
      debug: config.debug,
      debug_label: "Session ingest"
    )
  end

  @doc """
  Sends `method` to `url` with up to `:max_attempts` (default
  #{@max_attempts}) total attempts, and jittered exponential backoff (base
  #{@backoff_base_ms}ms) between them. A 429 response honors `Retry-After`
  (capped at #{@max_retry_after_ms}ms) instead of the usual backoff, unless
  `:honor_retry_after` is `false`. `req_opts` is forwarded to
  `Req.request/1` as-is (`:body`, `:headers`, `:receive_timeout`, ...)
  after stripping this function's own options:

    * `:debug` (default `false`) / `:debug_label` (default `"request"`) --
      diagnostic logging only.
    * `:max_attempts` (default #{@max_attempts}) -- total attempt budget.
    * `:honor_retry_after` (default `true`) -- whether a 429's
      `Retry-After` overrides the usual backoff delay.
    * `:sleep_fun` (default `&Process.sleep/1`) -- the delay function
      called between attempts, injectable so a caller (namely this
      package's own tests) never has to wait on real wall-clock time,
      mirroring `sdks/ruby/lib/alplus/retry.rb`'s `sleeper:`.

  Always returns `:ok`. Never raises -- an internal bug while building or
  sending the request is caught and (optionally) logged, same as every
  other outcome.
  """
  @spec request(atom(), String.t(), keyword()) :: :ok
  def request(method, url, req_opts \\ []) do
    {debug, req_opts} = Keyword.pop(req_opts, :debug, false)
    debug = debug == true

    {debug_label, req_opts} = Keyword.pop(req_opts, :debug_label, "request")
    {raw_max_attempts, req_opts} = Keyword.pop(req_opts, :max_attempts, @max_attempts)

    max_attempts =
      if is_integer(raw_max_attempts) and raw_max_attempts > 0,
        do: raw_max_attempts,
        else: @max_attempts

    {raw_honor_retry_after, req_opts} = Keyword.pop(req_opts, :honor_retry_after, true)
    honor_retry_after = raw_honor_retry_after == true

    {raw_sleep_fun, req_opts} = Keyword.pop(req_opts, :sleep_fun, &Process.sleep/1)
    sleep_fun = if is_function(raw_sleep_fun, 1), do: raw_sleep_fun, else: &Process.sleep/1
    req_opts = Keyword.put_new(req_opts, :retry, false)

    opts = %{
      debug: debug,
      label: debug_label,
      max_attempts: max_attempts,
      honor_retry_after: honor_retry_after,
      sleep_fun: sleep_fun
    }

    try do
      attempt(method, url, req_opts, 1, opts)
    rescue
      error ->
        log_debug(
          debug,
          debug_label,
          "internal error: #{Exception.format(:error, error, __STACKTRACE__)}"
        )
    end

    :ok
  end

  @spec attempt(atom(), String.t(), keyword(), pos_integer(), retry_opts()) :: :ok
  defp attempt(method, url, req_opts, attempt_no, opts) do
    req_opts
    |> Keyword.merge(method: method, url: url)
    |> Req.request()
    |> handle_attempt(method, url, req_opts, attempt_no, opts)
  end

  @spec handle_attempt(
          {:ok, Req.Response.t()} | {:error, term()},
          atom(),
          String.t(),
          keyword(),
          pos_integer(),
          retry_opts()
        ) :: :ok
  defp handle_attempt(
         {:ok, %Req.Response{status: status}},
         _method,
         _url,
         _req_opts,
         _attempt_no,
         _opts
       )
       when status in 200..299 do
    :ok
  end

  defp handle_attempt(
         {:ok, %Req.Response{status: status} = response},
         method,
         url,
         req_opts,
         attempt_no,
         opts
       )
       when is_integer(attempt_no) do
    log_debug(
      opts.debug,
      opts.label,
      "responded #{status} (attempt #{attempt_no}/#{opts.max_attempts})"
    )

    cond do
      status in @permanent_statuses ->
        :ok

      attempt_no >= opts.max_attempts ->
        log_debug(
          opts.debug,
          opts.label,
          "exhausted #{opts.max_attempts} attempts (last status #{status})"
        )

        :ok

      true ->
        delay_ms =
          if status == 429 and opts.honor_retry_after,
            do: retry_after_ms(response) || backoff_ms(attempt_no),
            else: backoff_ms(attempt_no)

        opts.sleep_fun.(delay_ms)
        attempt(method, url, req_opts, attempt_no + 1, opts)
    end
  end

  defp handle_attempt({:error, reason}, method, url, req_opts, attempt_no, opts)
       when is_integer(attempt_no) do
    log_debug(
      opts.debug,
      opts.label,
      "failed: #{inspect(reason)} (attempt #{attempt_no}/#{opts.max_attempts})"
    )

    if attempt_no >= opts.max_attempts do
      log_debug(
        opts.debug,
        opts.label,
        "exhausted #{opts.max_attempts} attempts: #{inspect(reason)}"
      )

      :ok
    else
      opts.sleep_fun.(backoff_ms(attempt_no))
      attempt(method, url, req_opts, attempt_no + 1, opts)
    end
  end

  defp backoff_ms(attempt_no) do
    exponential = @backoff_base_ms * :math.pow(2, attempt_no - 1)
    jitter_factor = 1 - @backoff_jitter + :rand.uniform() * (2 * @backoff_jitter)
    round(exponential * jitter_factor)
  end

  defp retry_after_ms(%Req.Response{} = response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, _} <- Float.parse(value),
         true <- seconds >= 0 do
      min(round(seconds * 1000), @max_retry_after_ms)
    else
      _ -> nil
    end
  end

  defp log_debug(false, _label, _message), do: :ok

  defp log_debug(true, label, message) do
    Logger.debug("alplus_sdk: #{label} #{message}")
  end
end
