defmodule Synapsis.Agent.Heartbeat.LocalSchedulerTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Heartbeat.LocalScheduler

  test "status returns snapshot with degraded flag and entries list" do
    snapshot = LocalScheduler.status()
    assert is_map(snapshot)
    assert is_boolean(snapshot.degraded?)
    assert is_list(snapshot.entries)
  end
end
