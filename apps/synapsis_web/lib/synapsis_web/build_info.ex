defmodule SynapsisWeb.BuildInfo.Source do
  @moduledoc false

  @project_root Path.expand("../../../..", __DIR__)

  def git_ref do
    case System.get_env("SYNAPSIS_GIT_REF") do
      ref when ref in [nil, ""] -> git_head()
      ref -> ref
    end
  end

  def release_time do
    case System.get_env("SYNAPSIS_RELEASE_TIME") do
      "" -> nil
      time -> time
    end
  end

  defp git_head do
    if git = System.find_executable("git") do
      port =
        Port.open({:spawn_executable, git}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["rev-parse", "HEAD"],
          cd: @project_root
        ])

      receive_git(port, "", System.monotonic_time(:millisecond) + 2_000)
    end
  rescue
    ArgumentError -> nil
  end

  defp receive_git(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> receive_git(port, output <> data, deadline)
      {^port, {:exit_status, 0}} -> String.trim(output)
      {^port, {:exit_status, _status}} -> nil
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        nil
    end
  end
end

defmodule SynapsisWeb.BuildInfo do
  @moduledoc false

  @environment Mix.env()
  @git_ref SynapsisWeb.BuildInfo.Source.git_ref()
  @release_time SynapsisWeb.BuildInfo.Source.release_time()
  @build_time DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  def info do
    %{
      version: to_string(Application.spec(:synapsis_web, :vsn) || "unknown"),
      environment: @environment,
      git_ref: @git_ref,
      release_time: @release_time,
      build_time: @build_time
    }
  end

  # Cached BEAM files must retain metadata for the source being built.
  def __mix_recompile__? do
    SynapsisWeb.BuildInfo.Source.git_ref() != @git_ref or
      SynapsisWeb.BuildInfo.Source.release_time() != @release_time
  end
end
