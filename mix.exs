defmodule AlplusSDK.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Alplus-Tech/sdk-elixir"

  def project do
    [
      app: :alplus_sdk,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: true, threshold: 99.9],
      deps: deps(),
      description: "Observe for Phoenix. Add a child and a plug.",
      package: package(),
      docs: [
        source_url: @source_url,
        extras: ["README.md"],
        main: "readme",
        filter_modules: ~r/^AlplusSDK(\.Plug|\.Test)?$/
      ]
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
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
