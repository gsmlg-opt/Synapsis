defmodule SynapsisCore.MixProject do
  use Mix.Project

  @version "0.3.1"

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
      {:backplane_agent_runtime, "~> 1.10.95"},
      {:backplane_skill_protocol, "~> 1.10.94"},
      {:phoenix_pubsub, "~> 2.4.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:tzdata, "~> 1.2.2"},
      {:file_system, "~> 1.0"},
      {:gaoxy_test, "~> 0.16.6", only: :test},
      {:formata, "~> 0.3.5"},
      {:http_fetch, "~> 1.0.0-rc.20"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
