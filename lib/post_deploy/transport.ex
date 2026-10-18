defmodule PostDeploy.Transport do
  @moduledoc false

  require Logger

  alias PostDeploy.Config

  @max_attempts 3
  @backoff_base_ms 500
  @backoff_jitter 0.5
  @max_retry_after_ms 30_000
  @permanent_statuses [400, 401, 403, 404]

  @typep retry_opts :: %{
           debug: boolean(),
           label: String.t(),
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

  @doc """
  Sends `method` to `url` with up to #{@max_attempts} total attempts, and
  jittered exponential backoff (base #{@backoff_base_ms}ms) between them. A
  429 response honors `Retry-After` (capped at #{@max_retry_after_ms}ms)
  instead of the usual backoff. `req_opts` is forwarded to `Req.request/1`
  as-is (`:body`, `:headers`, `:receive_timeout`, ...) after stripping this
  function's own options:

    * `:debug` (default `false`) / `:debug_label` (default `"request"`) --
      diagnostic logging only.
    * `:sleep_fun` (default `&Process.sleep/1`) -- the delay function
      called between attempts, injectable so a caller (namely this
      package's own tests) never has to wait on real wall-clock time,
      mirroring `sdks/ruby/lib/postdeploy/retry.rb`'s `sleeper:`.

  Always returns `:ok`. Never raises -- an internal bug while building or
  sending the request is caught and (optionally) logged, same as every
  other outcome.
  """
  @spec request(atom(), String.t(), keyword()) :: :ok
  def request(method, url, req_opts \\ []) do
    {debug, req_opts} = Keyword.pop(req_opts, :debug, false)
    debug = debug == true

    {debug_label, req_opts} = Keyword.pop(req_opts, :debug_label, "request")
    {raw_sleep_fun, req_opts} = Keyword.pop(req_opts, :sleep_fun, &Process.sleep/1)
    sleep_fun = if is_function(raw_sleep_fun, 1), do: raw_sleep_fun, else: &Process.sleep/1
    req_opts = Keyword.put_new(req_opts, :retry, false)

    opts = %{debug: debug, label: debug_label, sleep_fun: sleep_fun}

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
      "responded #{status} (attempt #{attempt_no}/#{@max_attempts})"
    )

    cond do
      status in @permanent_statuses ->
        :ok

      attempt_no >= @max_attempts ->
        log_debug(
          opts.debug,
          opts.label,
          "exhausted #{@max_attempts} attempts (last status #{status})"
        )

        :ok

      true ->
        delay_ms =
          if status == 429,
            do: retry_after_ms(response) || backoff_ms(attempt_no),
            else: backoff_ms(attempt_no)

        opts.sleep_fun.(delay_ms)
        attempt(method, url, req_opts, attempt_no + 1, opts)
    end
  end

  defp handle_attempt({:error, reason}, method, url, req_opts, attempt_no, opts)
       when is_integer(attempt_no) do
    reason_text = inspect(reason)

    log_debug(
      opts.debug,
      opts.label,
      "failed: #{reason_text} (attempt #{attempt_no}/#{@max_attempts})"
    )

    if attempt_no >= @max_attempts do
      log_debug(
        opts.debug,
        opts.label,
        "exhausted #{@max_attempts} attempts: #{reason_text}"
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
         true <- Regex.match?(~r/\A[0-9]+\z/, value) do
      min(String.to_integer(value) * 1000, @max_retry_after_ms)
    else
      _ -> nil
    end
  end

  defp log_debug(false, _label, _message), do: :ok

  defp log_debug(true, label, message), do: Logger.debug("postdeploy_sdk: #{label} #{message}")
end
