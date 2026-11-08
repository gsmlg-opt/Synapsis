defmodule SynapsisAgent.MixProject do
  use Mix.Project

  @version "0.2.4"

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
      {:synapsis_mcp, in_umbrella: true},
      {:synapsis_workspace, in_umbrella: true},
      {:backplane_agent_runtime, "~> 1.10.61"},
      {:jsonschex, "~> 0.10.0"},
      {:crontab, "~> 1.2.1"},
      {:tzdata, "~> 1.2.2"},
      {:gaoxy_test, "~> 0.15.2", only: :test},
      {:synapsis_sandbox, in_umbrella: true, only: :test}
    ]
  end
end
