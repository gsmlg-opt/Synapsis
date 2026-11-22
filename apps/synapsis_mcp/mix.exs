defmodule SynapsisMcp.MixProject do
  use Mix.Project

  @version "0.3.1"

  def project do
    [
      app: :synapsis_mcp,
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
      mod: {SynapsisMcp.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_core, in_umbrella: true},
      {:synapsis_data, in_umbrella: true},
      {:synapsis_provider, in_umbrella: true},
      {:backplane_mcp_protocol, "~> 1.10.94"},
      {:backplane_skill_protocol, "~> 1.10.94"},
      {:gaoxy_test, "~> 0.16.6", only: :test},
      {:formata, "~> 0.3.5"},
      {:http_fetch, "~> 1.0.0-rc.20"}
    ]
  end
end
