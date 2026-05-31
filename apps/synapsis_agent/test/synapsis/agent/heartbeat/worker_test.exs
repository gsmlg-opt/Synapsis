defmodule Synapsis.Agent.Heartbeat.WorkerTest do
  # Oban-based Worker.perform/1 removed in ADR-006 C3.
  # Execution logic lives in Worker.execute/1, called by LocalScheduler.
  # Integration tests covering LocalScheduler + execute/1 belong here.
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Heartbeat.Worker

  test "execute/1 returns :ok for a disabled config" do
    config = %{
      id: "test-id",
      name: "disabled",
      schedule: "0 9 * * *",
      enabled: false,
      prompt: "hello"
    }

    assert :ok = Worker.execute(config)
  end
end
