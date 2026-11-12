defmodule SynapsisServer.MixProject do
  use Mix.Project

  @version "0.2.4"

  def project do
    [
      app: :synapsis_server,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {SynapsisServer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_core, in_umbrella: true},
      {:synapsis_agent, in_umbrella: true},
      {:synapsis_provider, in_umbrella: true},
      {:synapsis_mcp, in_umbrella: true},
      {:synapsis_sandbox, in_umbrella: true},
      {:synapsis_samgita, in_umbrella: true},
      {:phoenix, "~> 1.8.16"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.2.13"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:gaoxy_test, "~> 0.15.1", only: :test},
      {:mint_web_socket, "~> 1.0", only: :test},
      {:dns_cluster, "~> 0.3.1"},
      {:gaoxy_http, "~> 0.15.1"},
      {:websock_adapter, "~> 0.15.1", hex: :gaoxy_websock_adapter, override: true},
      {:cors_plug, "~> 3.0"},
      {:duskmoon_bundler, "~> 10.1.6", runtime: Mix.env() in [:dev, :test]}
    ]
  end
end
