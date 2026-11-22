defmodule SynapsisLocalAgents.MixProject do
  use Mix.Project

  @version "0.3.1"

  def project do
    [
      app: :synapsis_local_agents,
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
    [extra_applications: [:logger], mod: {SynapsisLocalAgents.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_core, in_umbrella: true},
      {:synapsis_data, in_umbrella: true},
      {:samgita_codex_driver, "~> 0.5.0"},
      {:samgita_protocol_websocket, "~> 0.5.0"},
      {:formata, "~> 0.3.5"}
    ]
  end
end
