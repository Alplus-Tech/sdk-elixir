# alplus_sdk

Error reporting for [AL+ Observe](https://alplus.dev). Elixir and Phoenix.

## Install

```elixir
# mix.exs
{:alplus_sdk, "~> 0.1"}
```

Set `ALPLUS_KEY` (an ingest key with the `ingest` scope).

## Phoenix

```elixir
# application.ex
children = [
  {AlplusSDK, []},
  MyAppWeb.Endpoint
]

# endpoint.ex, first plug
plug AlplusSDK.Plug
```

`start_link/1` attaches the OTP logger handler and Phoenix
`[:phoenix, :error_rendered]`. Unhandled crashes become Observe events.
The plug opens a crash-free session per request.

Identify the current user after the plug:

```elixir
AlplusSDK.set_user(%{id: user.id, email: user.email})
AlplusSDK.set_tag("org_id", org.id)
```

## Capture

```elixir
try do
  risky()
rescue
  exception ->
    AlplusSDK.capture_exception(exception, stacktrace: __STACKTRACE__)
end

AlplusSDK.capture_message("low disk space", "warning")
```

Both calls return an `err_` event id and never raise, even if AL+ is
unreachable.

## Heartbeat

```elixir
AlplusSDK.heartbeat(token)
AlplusSDK.heartbeat(token, :fail)
```

Token is the auth. A running client is not required.

## Config

Env vars: `ALPLUS_KEY`, `ALPLUS_ENDPOINT`, `ALPLUS_ENVIRONMENT`,
`ALPLUS_RELEASE`.

Explicit `start_link/1` opts win. `config.exs` is the middle layer:

```elixir
config :alplus_sdk, config: [
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
start_supervised!({AlplusSDK, key: "alp_test", test: true})

AlplusSDK.capture_exception(%RuntimeError{message: "boom"})
AlplusSDK.flush()

[item] = AlplusSDK.Test.events()
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
