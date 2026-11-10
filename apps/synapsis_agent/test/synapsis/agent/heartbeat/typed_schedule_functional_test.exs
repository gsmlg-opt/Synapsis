defmodule Synapsis.Agent.Heartbeat.TypedScheduleFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Agent.Heartbeat.Schedule

  @fixture Path.expand("../../../fixtures/openclaw/488631c/schedule-computation.json", __DIR__)

  test "matches all pinned reference timestamps and subsequent at/every computations" do
    observations = @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("observations")
    assert length(observations) == 12

    for observation <- observations do
      schedule = observation["schedule"]

      for sample <- [observation, observation["subsequent"]] do
        now = DateTime.from_unix!(sample["nowMs"], :millisecond)
        assert {:ok, actual} = Schedule.next_after(schedule, "Etc/UTC", now)
        assert actual.time_zone == "Etc/UTC"

        assert DateTime.to_unix(actual, :millisecond) == sample["nextRunAtMs"],
               "reference #{observation["id"]} at #{sample["nowMs"]}"
      end
    end
  end

  test "absolute schedules interpret date-only and offsetless values as UTC" do
    now = ~U[2026-10-26 23:59:00Z]

    for at <- ["2026-10-27", "2026-10-27T00:00:00", "2026-10-27T05:45:00+05:45"] do
      assert {:ok, ~U[2026-10-27 00:00:00Z]} =
               Schedule.next_after(%{"kind" => "at", "at" => at}, "Asia/Shanghai", now)
    end
  end

  test "pure one-shot computation has no future occurrence at or after its target" do
    schedule = %{"kind" => "at", "at" => "2026-10-27T10:01:00Z"}

    for now <- [~U[2026-10-27 10:01:00Z], ~U[2026-10-27 10:02:00Z]] do
      assert :none = Schedule.next_after(schedule, "Etc/UTC", now)
    end
  end

  test "interval occurrences retain their original phase over repeated exact boundaries" do
    anchor = 1_793_095_199_500
    schedule = %{"kind" => "every", "everyMs" => 1_500, "anchorMs" => anchor}

    for step <- 0..30 do
      now = DateTime.from_unix!(anchor + step * 1_500, :millisecond)
      assert {:ok, following} = Schedule.next_after(schedule, "Etc/UTC", now)
      assert DateTime.to_unix(following, :millisecond) == anchor + (step + 1) * 1_500
    end
  end

  test "legacy and typed cron use the configured zone and typed cron can carry its own zone" do
    now = ~U[2026-10-27 00:00:00Z]
    expected = ~U[2026-10-27 18:15:00Z]

    for schedule <- ["0 0 * * *", %{"kind" => "cron", "expr" => "0 0 * * *"}] do
      assert {:ok, ^expected} = Schedule.next_after(schedule, "Asia/Kathmandu", now)
    end

    assert {:ok, ^expected} =
             Schedule.next_after(
               %{"kind" => "cron", "expr" => "0 0 * * *", "tz" => "Asia/Kathmandu"},
               "Etc/UTC",
               now
             )
  end
end
