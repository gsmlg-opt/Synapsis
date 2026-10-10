defmodule SynapsisProvider.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :synapsis_provider,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_data, in_umbrella: true},
      {:backplane_ai_protocol, "~> 1.10.17"},
      {:req, "~> 0.7"},
      {:finch, "~> 0.24"},
      {:jason, "~> 1.4"},
      {:bypass, "~> 2.1", only: :test},
      # Security floors for Bypass's test-only Plug/Cowboy transport.
      {:cowboy, "~> 2.20", only: :test},
      {:cowlib, "~> 2.21", only: :test}
    ]
  end
end
