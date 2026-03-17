defmodule Synapsis.HeartbeatConfigTest do
  use Synapsis.DataCase

  alias Synapsis.HeartbeatConfig

  @valid_attrs %{
    name: "morning-briefing",
    schedule: "30 7 * * 1-5",
    prompt: "Summarize overnight activity."
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, @valid_attrs)
      assert changeset.valid?
    end

    test "validates cron expression format" do
      attrs = Map.put(@valid_attrs, :schedule, "invalid")
      changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:schedule]
    end

    test "requires name" do
      attrs = Map.delete(@valid_attrs, :name)
      changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, attrs)
      refute changeset.valid?
    end

    test "requires prompt" do
      attrs = Map.delete(@valid_attrs, :prompt)
      changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, attrs)
      refute changeset.valid?
    end

    test "requires schedule" do
      attrs = Map.delete(@valid_attrs, :schedule)
      changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, attrs)
      refute changeset.valid?
    end

    test "defaults enabled to false" do
      changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :enabled) == false
    end

    test "defaults keep_history to false" do
      changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :keep_history) == false
    end

    test "inserts valid config" do
      {:ok, config} =
        %HeartbeatConfig{}
        |> HeartbeatConfig.changeset(@valid_attrs)
        |> Repo.insert()

      assert config.name == "morning-briefing"
      assert config.schedule == "30 7 * * 1-5"
      assert config.enabled == false
    end

    test "requires name uniqueness" do
      %HeartbeatConfig{}
      |> HeartbeatConfig.changeset(@valid_attrs)
      |> Repo.insert!()

      assert {:error, changeset} =
               %HeartbeatConfig{}
               |> HeartbeatConfig.changeset(@valid_attrs)
               |> Repo.insert()

      assert errors_on(changeset)[:name]
    end
  end
end
