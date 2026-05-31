defmodule Synapsis.Agent.Heartbeat.SchedulerTest do
  # The Oban-based Scheduler is deprecated (ADR-006 C3).
  # Only next_run_time/1 (cron parsing) is retained as a utility.
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Heartbeat.Scheduler

  describe "next_run_time/1" do
    test "parses valid 5-field cron expression" do
      assert {:ok, %DateTime{}} = Scheduler.next_run_time("30 7 * * 1-5")
    end

    test "parses every-minute expression" do
      assert {:ok, %DateTime{}} = Scheduler.next_run_time("* * * * *")
    end

    test "parses complex expression with ranges and steps" do
      assert {:ok, %DateTime{}} = Scheduler.next_run_time("*/5 9-17 * * 1-5")
    end

    test "returns a future time" do
      {:ok, next} = Scheduler.next_run_time("* * * * *")
      assert DateTime.compare(next, DateTime.utc_now()) == :gt
    end

    test "returns error for invalid expression" do
      assert {:error, _reason} = Scheduler.next_run_time("invalid")
    end

    test "returns error for completely invalid expression" do
      assert {:error, _reason} = Scheduler.next_run_time("not a cron at all!")
    end
  end
end
