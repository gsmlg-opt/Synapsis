defmodule Synapsis.Session.MonitorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Session.Monitor

  describe "new/0" do
    test "creates fresh state" do
      m = Monitor.new()
      assert m.iteration_count == 0
      assert m.tool_call_counts == %{}
      assert m.consecutive_empty_iterations == 0
      assert m.signals == []
    end
  end

  describe "record_tool_call/3" do
    test "first call returns :ok" do
      m = Monitor.new()
      {signal, _m} = Monitor.record_tool_call(m, "file_read", %{"path" => "/a.txt"})
      assert signal == :ok
    end

    test "duplicate below threshold returns :ok" do
      m = Monitor.new()
      {_, m} = Monitor.record_tool_call(m, "file_read", %{"path" => "/a.txt"})
      {signal, _m} = Monitor.record_tool_call(m, "file_read", %{"path" => "/a.txt"})
      assert signal == :ok
    end

    test "triggers at threshold (3rd identical call)" do
      m = Monitor.new()
      {_, m} = Monitor.record_tool_call(m, "bash", %{"command" => "mix test"})
      {_, m} = Monitor.record_tool_call(m, "bash", %{"command" => "mix test"})
      {signal, m} = Monitor.record_tool_call(m, "bash", %{"command" => "mix test"})

      assert {:duplicate_tool_call, _hash, 3} = signal
      assert length(m.signals) == 1
    end

    test "different inputs are not duplicates" do
      m = Monitor.new()
      {_, m} = Monitor.record_tool_call(m, "file_read", %{"path" => "/a.txt"})
      {_, m} = Monitor.record_tool_call(m, "file_read", %{"path" => "/b.txt"})
      {signal, _m} = Monitor.record_tool_call(m, "file_read", %{"path" => "/c.txt"})
      assert signal == :ok
    end
  end

  describe "record_iteration/2" do
    test "meaningful output resets stagnation counter" do
      m = Monitor.new()
      {signals, m} = Monitor.record_iteration(m, true)
      assert signals == []
      assert m.iteration_count == 1
      assert m.consecutive_empty_iterations == 0
    end

    test "empty iterations accumulate" do
      m = Monitor.new()
      {_, m} = Monitor.record_iteration(m, false)
      {_, m} = Monitor.record_iteration(m, false)
      assert m.consecutive_empty_iterations == 2
    end

    test "stagnation signal after 3 empty iterations" do
      m = Monitor.new()
      {_, m} = Monitor.record_iteration(m, false)
      {_, m} = Monitor.record_iteration(m, false)
      {signals, _m} = Monitor.record_iteration(m, false)

      assert Enum.any?(signals, fn
               {:stagnation, 3} -> true
               _ -> false
             end)
    end

    test "iteration warning at 20" do
      m = %{Monitor.new() | iteration_count: 19}
      {signals, _m} = Monitor.record_iteration(m, true)

      assert Enum.any?(signals, fn
               {:iteration_warning, 20} -> true
               _ -> false
             end)
    end

    test "meaningful output after stagnation resets counter" do
      m = %{Monitor.new() | consecutive_empty_iterations: 5}
      {_signals, m} = Monitor.record_iteration(m, true)
      assert m.consecutive_empty_iterations == 0
    end
  end

  describe "record_test_result/2" do
    test "first result does not signal" do
      m = Monitor.new()
      {signal, m} = Monitor.record_test_result(m, :passing)
      assert signal == :ok
      assert m.last_test_status == :passing
    end

    test "passing to failing signals regression" do
      m = %{Monitor.new() | last_test_status: :passing}
      {signal, m} = Monitor.record_test_result(m, :failing)

      assert {:test_regression, %{pass_to_fail: 1}} = signal
      assert m.test_regressions == 1
    end

    test "failing to failing does not signal" do
      m = %{Monitor.new() | last_test_status: :failing}
      {signal, _m} = Monitor.record_test_result(m, :failing)
      assert signal == :ok
    end

    test "failing to passing does not signal" do
      m = %{Monitor.new() | last_test_status: :failing}
      {signal, _m} = Monitor.record_test_result(m, :passing)
      assert signal == :ok
    end

    test "multiple regressions accumulate" do
      m = %{Monitor.new() | last_test_status: :passing}
      {_, m} = Monitor.record_test_result(m, :failing)
      m = %{m | last_test_status: :passing}
      {signal, m} = Monitor.record_test_result(m, :failing)

      assert {:test_regression, %{pass_to_fail: 2}} = signal
      assert m.test_regressions == 2
    end
  end

  describe "summary/1" do
    test "returns diagnostic map" do
      m = Monitor.new()
      {_, m} = Monitor.record_tool_call(m, "bash", %{"command" => "echo hi"})
      {_, m} = Monitor.record_iteration(m, true)

      s = Monitor.summary(m)
      assert s.iteration_count == 1
      assert s.unique_tool_calls == 1
      assert s.max_duplicate_count == 1
      assert s.consecutive_empty_iterations == 0
    end
  end

  describe "worst_signal/1" do
    test "returns :ok when no signals" do
      assert Monitor.worst_signal(Monitor.new()) == :ok
    end

    test "returns highest severity signal" do
      m = %{
        Monitor.new()
        | signals: [
            {:iteration_warning, 20},
            {:test_regression, %{pass_to_fail: 1}},
            {:stagnation, 3}
          ]
      }

      assert {:test_regression, _} = Monitor.worst_signal(m)
    end
  end
end
