defmodule Synapsis.Agent.RunReconcilerTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.RunReconciler
  alias Synapsis.AgentRun

  defp run(attrs) do
    AgentRun.from_store(
      Map.merge(
        %{
          id: "r1",
          kind: "manual",
          status: "running",
          source: "system",
          prompt: "x",
          tool_profile: "read_only",
          recovery_state: %{}
        },
        attrs
      )
    )
  end

  test "keeps terminal runs" do
    r = run(%{status: "completed"})
    assert {:keep, ^r} = RunReconciler.classify(r, %{})
  end

  test "keeps alive incomplete runs" do
    r = run(%{status: "running"})
    assert {:keep, ^r} = RunReconciler.classify(r, %{alive?: true})
  end

  test "deadline exceeded becomes timed_out" do
    deadline = DateTime.add(DateTime.utc_now(), -60, :second)
    r = run(%{deadline_at: deadline})

    assert {:reconcile, "timed_out", _} =
             RunReconciler.classify(r, %{now: DateTime.utc_now()})
  end

  test "side effect intent becomes unknown_outcome" do
    r = run(%{recovery_state: %{"side_effect_intent" => true}})

    assert {:reconcile, "unknown_outcome", _} = RunReconciler.classify(r, %{})
  end

  test "no side effect becomes failed" do
    assert {:reconcile, "failed", _} = RunReconciler.classify(run(%{}), %{})
  end
end
