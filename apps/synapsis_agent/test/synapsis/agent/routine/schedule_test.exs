defmodule Synapsis.Agent.Routine.ScheduleTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Routine.Schedule

  test "occurrence_key is deterministic UTC iso" do
    dt = ~U[2026-03-08 14:30:00Z]
    assert Schedule.occurrence_key("r1", dt) == "r1:2026-03-08T14:30:00Z"
  end

  test "next_after for UTC cron" do
    now = ~U[2026-09-04 10:00:01Z]
    assert {:ok, next} = Schedule.next_after("0 * * * *", "Etc/UTC", now)
    assert DateTime.compare(next, now) == :gt
    assert next.minute == 0
  end

  test "fold_local_result prefers earlier ambiguous instant" do
    earlier = ~U[2025-11-02 05:30:00Z]
    later = ~U[2025-11-02 06:30:00Z]

    assert {:ok, ^earlier} = Schedule.fold_local_result({:ambiguous, earlier, later})
    assert {:ok, ^earlier} = Schedule.fold_local_result({:ambiguous, later, earlier})
  end

  test "fold_local_result uses after-gap for missing local time" do
    before = ~U[2025-03-09 06:59:00Z]
    after_gap = ~U[2025-03-09 07:00:00Z]

    assert {:ok, ^after_gap} = Schedule.fold_local_result({:gap, before, after_gap})
  end
end
