Code.require_file("rel/filesystem_runtime.exs", __DIR__)

defmodule Synapsis.MixProject do
  use Mix.Project

  @version "0.4.2"

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
      {:websock_adapter, "~> 0.16.6", hex: :gaoxy_websock_adapter, override: true}
    ]
  end

  defp aliases do
    [
      compile: [&compile_with_native_pty/1],
      "synapsis.run": ["compile", &prepare_code_mode/1, "phx.server"]
    ]
  end

  defp prepare_code_mode(_) do
    if :os.type() == {:unix, :darwin} and
         not File.regular?(
           Application.app_dir(
             :backplane_agent_runtime,
             "priv/bin/backplane-local-command-session"
           )
         ),
       do: Mix.Task.run("backplane.command.build")

    runner =
      Path.join(
        Mix.Project.build_path(),
        "backplane_code_mode_runner/bin/backplane-code-mode-runner"
      )

    unless System.get_env("BACKPLANE_CODE_MODE_RUNNER") || File.regular?(runner),
      do: Mix.Task.run("backplane.code_mode.build", ["--no-compile"])
  end

  defp compile_with_native_pty(args) do
    result = Mix.Task.run("compile", args)

    if match?({status, _} when status in [:ok, :noop], result) and
         :os.type() == {:unix, :linux} and "--no-compile" not in args,
       do: Mix.Task.run("backplane.pty.build")

    result
  end
end
