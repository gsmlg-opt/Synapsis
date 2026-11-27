defmodule Synapsis.Agent.TestSupport.RunnerProcess do
  import ExUnit.Assertions

  def assert_os_reaped(pid) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_os_reaped(pid, deadline)
    refute os_process_present?(pid)
  end

  defp await_os_reaped(pid, deadline) do
    if os_process_present?(pid) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_os_reaped(pid, deadline)
    end
  end

  def os_process_present?(pid) do
    if :os.type() == {:unix, :darwin} do
      helper =
        Application.app_dir(:backplane_agent_runtime, "priv/bin/backplane-local-command-session")

      {:ok, present?} =
        Backplane.AgentRuntime.Tools.LocalCommand.Platform.probe(helper, "--alive", pid)

      present?
    else
      File.exists?("/proc/#{pid}")
    end
  end
end
