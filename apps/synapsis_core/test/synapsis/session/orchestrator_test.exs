defmodule Synapsis.Session.OrchestratorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Session.{Orchestrator, Monitor}

  describe "decide/2" do
    test "continues when no issues" do
      m = Monitor.new()
      assert {:continue, "ok"} = Orchestrator.decide(m)
    end

    test "terminates at max iterations" do
      m = %{Monitor.new() | iteration_count: 25}
      assert {:terminate, reason} = Orchestrator.decide(m)
      assert reason =~ "maximum iterations"
    end

    test "terminates after multiple test regressions" do
      m = %{Monitor.new() | test_regressions: 3}
      assert {:terminate, reason} = Orchestrator.decide(m)
      assert reason =~ "test regressions"
    end

    test "escalates on duplicate tool calls" do
      m = Monitor.new()
      {_, m} = Monitor.record_tool_call(m, "bash", %{"command" => "mix test"})
      {_, m} = Monitor.record_tool_call(m, "bash", %{"command" => "mix test"})
      {_, m} = Monitor.record_tool_call(m, "bash", %{"command" => "mix test"})

      assert {:escalate, reason} = Orchestrator.decide(m)
      assert reason =~ "Duplicate tool calls"
    end

    test "escalates on first test regression" do
      m = %{Monitor.new() | test_regressions: 1}
      assert {:escalate, reason} = Orchestrator.decide(m)
      assert reason =~ "Test regression"
    end

    test "pauses on stagnation" do
      m = %{Monitor.new() | consecutive_empty_iterations: 3}
      assert {:pause, reason} = Orchestrator.decide(m)
      assert reason =~ "empty iterations"
    end

    test "warns but continues near iteration limit" do
      m = %{Monitor.new() | iteration_count: 21}
      assert {:continue, reason} = Orchestrator.decide(m)
      assert reason =~ "Approaching iteration limit"
    end

    test "respects custom max_iterations" do
      m = %{Monitor.new() | iteration_count: 10}
      assert {:terminate, _} = Orchestrator.decide(m, max_iterations: 10)
    end

    test "terminate takes priority over escalate" do
      # Both max iterations AND duplicate calls
      m = %{
        Monitor.new()
        | iteration_count: 25,
          signals: [{:duplicate_tool_call, 123, 3}]
      }

      assert {:terminate, _} = Orchestrator.decide(m)
    end

    test "escalate takes priority over pause" do
      # Both duplicate calls AND stagnation
      m = %{
        Monitor.new()
        | consecutive_empty_iterations: 5,
          signals: [{:duplicate_tool_call, 123, 3}]
      }

      assert {:escalate, _} = Orchestrator.decide(m)
    end

    test "continues with empty signals list" do
      m = %{Monitor.new() | signals: []}
      assert {:continue, "ok"} = Orchestrator.decide(m)
    end

    test "test_regressions below threshold escalates rather than terminates" do
      # 2 regressions is below the termination threshold (3) but above 0
      m = %{Monitor.new() | test_regressions: 2}
      assert {:escalate, reason} = Orchestrator.decide(m)
      assert reason =~ "Test regression"
    end

    test "test_regressions at exactly the threshold terminates" do
      m = %{Monitor.new() | test_regressions: 3}
      assert {:terminate, reason} = Orchestrator.decide(m)
      assert reason =~ "test regressions"
    end

    test "test_regressions above threshold still terminates" do
      m = %{Monitor.new() | test_regressions: 5}
      assert {:terminate, reason} = Orchestrator.decide(m)
      assert reason =~ "test regressions"
    end

    test "iteration count at max_iterations - 1 triggers approaching warning" do
      # Default max is 25; at 20 (>= 25-5) should warn
      m = %{Monitor.new() | iteration_count: 20}
      assert {:continue, reason} = Orchestrator.decide(m)
      assert reason =~ "Approaching iteration limit"
    end

    test "iteration count just below warning threshold returns ok" do
      # Default max is 25; warning at >= 20; 19 should be plain ok
      m = %{Monitor.new() | iteration_count: 19}
      assert {:continue, "ok"} = Orchestrator.decide(m)
    end

    test "custom max_iterations adjusts the warning threshold too" do
      # max_iterations: 15, warning at >= 10
      m = %{Monitor.new() | iteration_count: 10}
      assert {:continue, reason} = Orchestrator.decide(m, max_iterations: 15)
      assert reason =~ "Approaching iteration limit"

      # At 9, should be ok
      m2 = %{Monitor.new() | iteration_count: 9}
      assert {:continue, "ok"} = Orchestrator.decide(m2, max_iterations: 15)
    end

    test "stagnation exactly at threshold pauses" do
      m = %{Monitor.new() | consecutive_empty_iterations: 3}
      assert {:pause, _} = Orchestrator.decide(m)
    end

    test "stagnation below threshold continues" do
      m = %{Monitor.new() | consecutive_empty_iterations: 2}
      assert {:continue, "ok"} = Orchestrator.decide(m)
    end
  end

  describe "apply_decision/2" do
    test "continue has no actions" do
      result = Orchestrator.apply_decision({:continue, "ok"}, "session-1")
      assert result.decision == :continue
      assert result.actions == []
    end

    test "pause broadcasts and sets idle" do
      result = Orchestrator.apply_decision({:pause, "stagnation"}, "session-1")
      assert result.decision == :pause
      assert {:broadcast, "orchestrator_pause", _} = Enum.at(result.actions, 0)
      assert {:set_status, :idle} = Enum.at(result.actions, 1)
    end

    test "escalate invokes auditor" do
      result = Orchestrator.apply_decision({:escalate, "dup tools"}, "session-1")
      assert result.decision == :escalate
      assert {:broadcast, "orchestrator_escalate", _} = Enum.at(result.actions, 0)
      assert {:invoke_auditor, "dup tools"} = Enum.at(result.actions, 1)
    end

    test "terminate persists message and goes idle" do
      result = Orchestrator.apply_decision({:terminate, "max reached"}, "session-1")
      assert result.decision == :terminate
      assert {:broadcast, "orchestrator_terminate", _} = Enum.at(result.actions, 0)
      assert {:persist_message, "max reached"} = Enum.at(result.actions, 1)
      assert {:set_status, :idle} = Enum.at(result.actions, 2)
    end

    test "all decisions include reason in result" do
      for {decision, reason} <- [
            {:continue, "ok"},
            {:pause, "stalled"},
            {:escalate, "loop detected"},
            {:terminate, "done"}
          ] do
        result = Orchestrator.apply_decision({decision, reason}, "sess-x")
        assert result.reason == reason
        assert result.decision == decision
      end
    end

    test "continue returns exactly zero actions" do
      result = Orchestrator.apply_decision({:continue, "approaching limit"}, "sess-2")
      assert result.actions == []
    end

    test "pause has exactly 2 actions" do
      result = Orchestrator.apply_decision({:pause, "empty"}, "sess-3")
      assert length(result.actions) == 2
    end

    test "escalate has exactly 2 actions" do
      result = Orchestrator.apply_decision({:escalate, "dup"}, "sess-4")
      assert length(result.actions) == 2
    end

    test "terminate has exactly 3 actions" do
      result = Orchestrator.apply_decision({:terminate, "max"}, "sess-5")
      assert length(result.actions) == 3
    end

    test "broadcast actions include reason in payload" do
      result = Orchestrator.apply_decision({:pause, "waiting for user"}, "sess-6")
      {:broadcast, _event, payload} = Enum.at(result.actions, 0)
      assert payload.reason == "waiting for user"
    end
  end
end
