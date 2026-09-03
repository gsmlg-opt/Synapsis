defmodule Synapsis.Agent.Heartbeat.WorkerTerminalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Events.Emitter
  alias Synapsis.Agent.Events.TerminalWaiter

  test "typed failure is authoritative and does not fall back to transcript success" do
    session_id = "hb-fail-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        TerminalWaiter.await_after(session_id, [timeout_ms: 3_000], fn ->
          Emitter.emit_session_failed(session_id, "provider down")
          :ok
        end)
      end)

    assert {:failed, %{payload: %{"message" => "provider down"}}} = Task.await(task, 5_000)
  end

  test "waiter timeout does not invent a successful completion from absent transcript" do
    session_id = "hb-timeout-#{System.unique_integer([:positive])}"

    assert {:waiter_timeout, reason} =
             TerminalWaiter.await(session_id, timeout_ms: 100)

    assert reason =~ "timed out"
  end
end
