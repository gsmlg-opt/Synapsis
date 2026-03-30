defmodule Synapsis.Agent.Heartbeat.SchedulerTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.Heartbeat.Scheduler
  alias Synapsis.HeartbeatConfig

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

    test "returns future time" do
      {:ok, next} = Scheduler.next_run_time("* * * * *")
      assert DateTime.compare(next, DateTime.utc_now()) == :gt
    end

    test "returns error for invalid expression" do
      assert {:error, _reason} = Scheduler.next_run_time("invalid")
    end

    test "returns error for expression with wrong field count" do
      assert {:error, _reason} = Scheduler.next_run_time("* * *")
    end
  end

  describe "load_enabled_configs/0" do
    test "returns empty list when no configs" do
      assert Scheduler.load_enabled_configs() == []
    end

    test "returns only enabled configs" do
      {:ok, _} =
        HeartbeatConfig.create(%{
          name: "enabled-one",
          schedule: "0 9 * * *",
          prompt: "Test",
          enabled: true
        })

      {:ok, _} =
        HeartbeatConfig.create(%{
          name: "disabled-one",
          schedule: "0 10 * * *",
          prompt: "Test",
          enabled: false
        })

      configs = Scheduler.load_enabled_configs()
      assert length(configs) == 1
      assert hd(configs).name == "enabled-one"
    end
  end
end
