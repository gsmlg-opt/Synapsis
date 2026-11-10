defmodule Synapsis.Agent.Heartbeat.CronStaggerFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Agent.Heartbeat.Schedule

  @fixture Path.expand("../../../fixtures/openclaw/488631c/cron-stagger.json", __DIR__)

  test "next instants match the unchanged pinned source with actual Croner" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    observations = fixture["observations"]
    assert length(observations) >= 8

    for observation <- observations do
      job = observation["job"]
      now = DateTime.from_unix!(observation["nowMs"], :millisecond)

      assert {:ok, actual} = Schedule.next_after(job["schedule"], "Etc/UTC", now, job["id"])

      assert DateTime.to_unix(actual, :millisecond) == observation["nextRunAtMs"],
             observation["id"]
    end
  end

  test "zero and a one-millisecond window retain exact base instants" do
    for window <- [0, 1] do
      schedule = %{"kind" => "cron", "expr" => "0 * * * *", "staggerMs" => window}

      assert {:ok, ~U[2026-10-28 11:00:00Z]} =
               Schedule.next_after(
                 schedule,
                 "Etc/UTC",
                 ~U[2026-10-28 10:00:00Z],
                 "395da548-7e5c-4efe-998b-9dd58fe623ad"
               )
    end
  end
end
