defmodule Synapsis.Agent.Heartbeat.WorkerTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.Heartbeat.Worker
  alias Synapsis.HeartbeatConfig

  describe "perform/1" do
    test "returns error when config not found" do
      job = %Oban.Job{args: %{"heartbeat_id" => Ecto.UUID.generate()}}
      assert {:error, :config_not_found} = Worker.perform(job)
    end

    test "returns :ok when config is disabled" do
      {:ok, config} =
        HeartbeatConfig.create(%{
          name: "disabled-test-#{System.unique_integer([:positive])}",
          schedule: "0 9 * * *",
          prompt: "Test prompt",
          enabled: false
        })

      job = %Oban.Job{args: %{"heartbeat_id" => config.id}}
      assert :ok = Worker.perform(job)
    end
  end

  describe "new/2" do
    test "creates a valid Oban job changeset" do
      changeset =
        Worker.new(%{"heartbeat_id" => Ecto.UUID.generate()},
          scheduled_at: DateTime.utc_now(),
          unique: [period: 60, keys: [:heartbeat_id]]
        )

      assert changeset.valid?
      assert changeset.changes.queue == "heartbeat"
    end
  end
end
