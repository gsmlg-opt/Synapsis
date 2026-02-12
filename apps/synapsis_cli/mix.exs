defmodule SynapsisCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :synapsis_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [main_module: SynapsisCli.Main]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:owl, "~> 0.12"}
    ]
  end
end
