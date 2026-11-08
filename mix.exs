Code.require_file("rel/filesystem_runtime.exs", __DIR__)

defmodule Synapsis.MixProject do
  use Mix.Project

  @version "0.2.4"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp releases do
    [
      synapsis: [
        applications: [
          synapsis_data: :permanent,
          synapsis_agent: :permanent,
          synapsis_provider: :permanent,
          synapsis_core: :permanent,
          synapsis_server: :permanent,
          synapsis_workspace: :permanent,
          synapsis_web: :permanent
        ],
        steps: [:assemble, &Synapsis.Release.FilesystemRuntime.bundle/1, :tar]
      ]
    ]
  end

  defp deps do
    [
      {:websock_adapter, "~> 0.15.1", hex: :gaoxy_websock_adapter, override: true}
    ]
  end

  defp aliases do
    [
      compile: [&compile_with_native_pty/1],
      "synapsis.run": ["phx.server"]
    ]
  end

  defp compile_with_native_pty(args) do
    result = Mix.Task.run("compile", args)

    if match?({status, _} when status in [:ok, :noop], result) and
         :os.type() == {:unix, :linux} and "--no-compile" not in args,
       do: Mix.Task.run("backplane.pty.build")

    result
  end
end
