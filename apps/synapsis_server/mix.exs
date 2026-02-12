defmodule SynapsisServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :synapsis_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SynapsisServer.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:synapsis_core, in_umbrella: true},
      {:synapsis_web, in_umbrella: true}
    ]
  end
end
