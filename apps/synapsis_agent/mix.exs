defmodule SynapsisAgent.MixProject do
  use Mix.Project

  @version "0.2.1"

  def project do
    [
      app: :synapsis_agent,
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
      extra_applications: [:logger],
      mod: {SynapsisAgent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_data, in_umbrella: true},
      {:synapsis_core, in_umbrella: true},
      {:synapsis_provider, in_umbrella: true},
      {:synapsis_mcp, in_umbrella: true, only: :test},
      {:synapsis_workspace, in_umbrella: true},
      # TODO(upstream): gsmlg-opt/backplane#60 — unblock the runtime upgrade.
      {:backplane_agent_runtime, "1.10.4"},
      {:crontab, "~> 1.2.1"},
      {:bypass, "~> 2.1", only: :test},
      {:cowboy, "~> 2.20.0", only: :test},
      {:cowlib, "~> 2.21.0", only: :test}
    ]
  end
end
