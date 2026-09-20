# postdeploy_sdk

Error reporting for [PostDeploy Observe](https://postdeploy.dev). Elixir and Phoenix.

Setup guide: [Elixir and Phoenix error tracking](https://postdeploy.dev/docs/observe/elixir).

## Install

```elixir
# mix.exs
{:postdeploy_sdk, "~> 0.2"}
```

Set `POSTDEPLOY_API_KEY` (an ingest key with the `ingest` scope).

## Phoenix

```elixir
# application.ex
children = [
  {PostDeploy, []},
  MyAppWeb.Endpoint
]

# endpoint.ex, first plug
plug PostDeploy.Plug
```

`start_link/1` attaches the OTP logger handler and Phoenix
`[:phoenix, :error_rendered]`. Unhandled crashes become Observe events.
The plug opens a crash-free session per request.

Identify the current user after the plug:

```elixir
PostDeploy.set_user(%{id: user.id, email: user.email})
PostDeploy.set_tag("org_id", org.id)
```

## Capture

```elixir
try do
  risky()
rescue
  exception ->
    PostDeploy.capture_exception(exception, stacktrace: __STACKTRACE__)
end

PostDeploy.capture_message("low disk space", "warning")
```

Both calls return an `err_` event id and never raise, even if PostDeploy is
unreachable.

## Heartbeat

```elixir
PostDeploy.heartbeat(token)
PostDeploy.heartbeat(token, :fail)
```

Heartbeat calls never raise. Each call makes at most two attempts and reuses
one UUIDv4 `ping_id` across retries. The server deduplicates a supplied ID per
monitor for 24 hours. Transport failures, `408`, `429`, and `5xx` responses
retry only. Each attempt has a five-second timeout. Delta-seconds
`Retry-After` is capped at two seconds; other retries use jittered backoff
around 500ms. Diagnostics redact the full heartbeat token.

## Config

Env vars: `POSTDEPLOY_API_KEY`, `POSTDEPLOY_INGEST_URL`, `POSTDEPLOY_ENVIRONMENT`,
`POSTDEPLOY_RELEASE`.

Explicit `start_link/1` opts win. `config.exs` is the middle layer:

```elixir
config :postdeploy_sdk, config: [
  environment: "production",
  sample_rate: 0.5,
  before_send: &MyApp.Observe.scrub/1
]
```

`before_send` receives the built item. Return `nil` to drop it. A raise
sends the original item.

Set `enabled?: false` to no-op capture. A missing key is then allowed.

## Tests

```elixir
start_supervised!({PostDeploy, key: "alp_test", test: true})

PostDeploy.capture_exception(%RuntimeError{message: "boom"})
PostDeploy.flush()

[item] = PostDeploy.Test.events()
assert item["exception"]["value"] == "boom"
```

Nothing hits the network.

## Development

```
cd sdks/elixir
export ALPLUS_CONTRACT_DIR=../../sdks/contract
mix deps.get
mix test
```
