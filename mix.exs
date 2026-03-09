defmodule Synapsis.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      releases: releases()
    ]
  end

  defp releases do
    [
      synapsis: [
        applications: [
          synapsis_data: :permanent,
          synapsis_agent: :load,
          synapsis_provider: :permanent,
          synapsis_core: :permanent,
          synapsis_server: :permanent,
          synapsis_plugin: :permanent,
          synapsis_web: :permanent
        ],
        steps: [:assemble, :tar]
      ]
    ]
  end

  defp deps do
    []
  end
end
