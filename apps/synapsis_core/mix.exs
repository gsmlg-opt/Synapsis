defmodule SynapsisCore.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :synapsis_core,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SynapsisCore.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_data, in_umbrella: true},
      {:synapsis_provider, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:req, "~> 0.5"},
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:oban, "~> 2.19"},
      {:file_system, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
