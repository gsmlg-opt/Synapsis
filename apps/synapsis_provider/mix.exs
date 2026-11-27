defmodule SynapsisProvider.MixProject do
  use Mix.Project

  @version "0.4.2"

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
      {:phoenix_pubsub, "~> 2.4.1"},
      {:backplane_ai_protocol, "~> 1.10.98"},
      {:gaoxy_test, "~> 0.16.6", only: :test},
      {:formata, "~> 0.3.5"},
      {:http_fetch, "~> 1.0.0-rc.20"},
      {:http_web_socket, "~> 1.0.0-rc.20"}
    ]
  end
end
