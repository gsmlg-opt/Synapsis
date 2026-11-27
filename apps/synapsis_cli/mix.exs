defmodule SynapsisCli.MixProject do
  use Mix.Project

  @version "0.4.2"

  def project do
    [
      app: :synapsis_cli,
      version: @version,
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
      {:owl, "~> 0.12"},
      {:gaoxy_test, "~> 0.16.6", only: :test},
      {:formata, "~> 0.3.5"},
      {:http_fetch, "~> 1.0.0-rc.20"}
    ]
  end
end
