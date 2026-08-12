defmodule AlplusSDK.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/abpaul/alplus"

  def project do
    [
      app: :alplus_sdk,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir client for AL+ Observe error reporting (POST /e/errors).",
      package: package(),
      docs: [source_url: @source_url]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
