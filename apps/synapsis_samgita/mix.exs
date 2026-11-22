defmodule SynapsisSamgita.MixProject do
  use Mix.Project

  @version "0.3.1"

  def project do
    [
      app: :synapsis_samgita,
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
    [extra_applications: [:logger], mod: {SynapsisSamgita.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_core, in_umbrella: true},
      {:synapsis_data, in_umbrella: true},
      {:synapsis_agent, in_umbrella: true},
      {:synapsis_local_agents, in_umbrella: true},
      {:http_web_socket, "~> 1.0.0-rc.5"},
      {:samgita_protocol, "~> 0.4.0"},
      {:samgita_protocol_websocket, "~> 0.4.0"},
      {:websock_adapter, "~> 0.15.1", hex: :gaoxy_websock_adapter, override: true},
      {:req, "~> 0.7.5"},
      {:jason, "~> 1.4"},
      {:gaoxy_test, "~> 0.15.1", only: :test}
    ]
  end
end
