defmodule PostDeploy.ConfigTest do
  @moduledoc """
  `System.put_env/2`/`delete_env/2` mutate real OS process env, which is
  global state shared across the VM -- this file runs `async: false` and
  restores whatever was there before each test.
  """

  use ExUnit.Case, async: false

  alias PostDeploy.Config

  @env_keys ~w(POSTDEPLOY_API_KEY POSTDEPLOY_INGEST_URL POSTDEPLOY_ENVIRONMENT POSTDEPLOY_RELEASE)

  setup do
    previous = for key <- @env_keys, into: %{}, do: {key, System.get_env(key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    for key <- @env_keys, do: System.delete_env(key)
    :ok
  end

  test "reads key/endpoint/environment/release from POSTDEPLOY_* env vars when no opt is given" do
    System.put_env("POSTDEPLOY_API_KEY", "alp_p_from_env")
    System.put_env("POSTDEPLOY_INGEST_URL", "https://custom.ingest.example")
    System.put_env("POSTDEPLOY_ENVIRONMENT", "staging")
    System.put_env("POSTDEPLOY_RELEASE", "v9.9.9")

    config = Config.new([])

    assert config.key == "alp_p_from_env"
    assert config.base_url == "https://custom.ingest.example"
    assert config.environment == "staging"
    assert config.release == "v9.9.9"
  end

  test "an explicit opt wins over the env var" do
    System.put_env("POSTDEPLOY_API_KEY", "alp_p_from_env")

    config = Config.new(key: "alp_p_explicit")

    assert config.key == "alp_p_explicit"
  end

  test "raises without a key from either opts or POSTDEPLOY_API_KEY" do
    assert_raise ArgumentError, ~r/POSTDEPLOY_API_KEY/, fn -> Config.new([]) end
  end

  test "enabled?: false does not require a key" do
    config = Config.new(enabled?: false)

    assert config.key == ""
    refute config.enabled?
  end

  test "test: true sets test? and defaults the post-error window to 0" do
    config = Config.new(key: "alp_p_x", test: true)

    assert config.test?
    assert config.post_error_log_window_ms == 0
  end

  test "defaults environment and base_url when nothing is configured" do
    config = Config.new(key: "alp_p_x")

    assert config.environment == "production"
    assert config.base_url == "https://ingest.postdeploy.dev"
    assert config.context_lines == 3
  end

  describe "sampled?/1" do
    test "always true at the default sample_rate (1.0)" do
      config = Config.new(key: "alp_p_x")
      assert Config.sampled?(config)
    end

    test "always false at sample_rate 0.0" do
      config = Config.new(key: "alp_p_x", sample_rate: 0.0)
      refute Config.sampled?(config)
    end
  end
end
