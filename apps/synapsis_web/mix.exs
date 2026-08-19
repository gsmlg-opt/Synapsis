defmodule SynapsisWeb.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :synapsis_web,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_server, in_umbrella: true},
      {:synapsis_agent, in_umbrella: true},
      {:synapsis_workspace, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_duskmoon, "~> 9.1"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:duskmoon_bundler_runtime, "~> 9.7"},
      {:duskmoon_bundler, "~> 9.7", runtime: Mix.env() in [:dev, :test]},
      {:lazy_html, ">= 0.1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "npm.install", "assets.build"],
      "assets.setup": ["npm.install"],
      "assets.build": ["duskmoon_bundler.build synapsis_web --tailwind"],
      "assets.deploy": [
        "phx.digest.clean",
        "duskmoon_bundler.build synapsis_web --tailwind",
        "phx.digest"
      ]
    ]
  end
end
