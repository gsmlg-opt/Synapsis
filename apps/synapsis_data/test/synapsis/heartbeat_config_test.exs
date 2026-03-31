defmodule Synapsis.HeartbeatConfigTest do
  use Synapsis.DataCase

  alias Synapsis.HeartbeatConfig

  @valid_attrs %{
    name: "test-heartbeat",
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

      assert config.name == "test-heartbeat"
      assert config.schedule == "30 7 * * 1-5"
      assert config.enabled == false
    end

    test "requires name uniqueness" do
      %HeartbeatConfig{}
      |> HeartbeatConfig.changeset(%{
        @valid_attrs
        | name: "unique-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

      # Insert same name again
      name = "dup-name-#{System.unique_integer([:positive])}"

      %HeartbeatConfig{}
      |> HeartbeatConfig.changeset(%{@valid_attrs | name: name})
      |> Repo.insert!()

      assert {:error, changeset} =
               %HeartbeatConfig{}
               |> HeartbeatConfig.changeset(%{@valid_attrs | name: name})
               |> Repo.insert()

      assert errors_on(changeset)[:name]
    end
  end

  describe "create/1" do
    test "inserts config with valid attrs" do
      name = "create-test-#{System.unique_integer([:positive])}"
      assert {:ok, config} = HeartbeatConfig.create(%{@valid_attrs | name: name})
      assert config.name == name
    end
  end

  describe "update_config/2" do
    test "updates config fields" do
      name = "update-test-#{System.unique_integer([:positive])}"
      {:ok, config} = HeartbeatConfig.create(%{@valid_attrs | name: name})
      assert {:ok, updated} = HeartbeatConfig.update_config(config, %{enabled: true})
      assert updated.enabled == true
    end
  end

  describe "update_config/2 toggle enabled" do
    test "updates enabled from false to true" do
      name = "toggle-test-#{System.unique_integer([:positive])}"
      {:ok, config} = HeartbeatConfig.create(%{@valid_attrs | name: name})
      assert config.enabled == false

      {:ok, updated} = HeartbeatConfig.update_config(config, %{enabled: true})
      assert updated.enabled == true
    end

    test "updates enabled from true to false" do
      name = "toggle-test-#{System.unique_integer([:positive])}"

      {:ok, config} =
        HeartbeatConfig.create(Map.merge(@valid_attrs, %{name: name, enabled: true}))

      assert config.enabled == true

      {:ok, updated} = HeartbeatConfig.update_config(config, %{enabled: false})
      assert updated.enabled == false
    end
  end

  describe "list_all/0" do
    test "returns configs ordered by name" do
      # Create test-specific configs and verify ordering
      name_z = "zzz-test-#{System.unique_integer([:positive])}"
      name_a = "aaa-test-#{System.unique_integer([:positive])}"

      HeartbeatConfig.create(%{name: name_z, schedule: "0 9 * * *", prompt: "Z"})
      HeartbeatConfig.create(%{name: name_a, schedule: "0 10 * * *", prompt: "A"})

      configs = HeartbeatConfig.list_all()
      names = Enum.map(configs, & &1.name)

      # Verify our test configs exist and are ordered
      z_idx = Enum.find_index(names, &(&1 == name_z))
      a_idx = Enum.find_index(names, &(&1 == name_a))
      assert a_idx < z_idx
    end
  end

  describe "list_enabled/0" do
    test "returns only enabled configs" do
      name_on = "enabled-test-#{System.unique_integer([:positive])}"
      name_off = "disabled-test-#{System.unique_integer([:positive])}"

      HeartbeatConfig.create(%{name: name_on, schedule: "0 9 * * *", prompt: "T", enabled: true})

      HeartbeatConfig.create(%{
        name: name_off,
        schedule: "0 10 * * *",
        prompt: "T",
        enabled: false
      })

      enabled = HeartbeatConfig.list_enabled()
      enabled_names = Enum.map(enabled, & &1.name)
      assert name_on in enabled_names
      refute name_off in enabled_names
    end
  end

  describe "delete_config/1" do
    test "removes config from database" do
      name = "delete-test-#{System.unique_integer([:positive])}"
      {:ok, config} = HeartbeatConfig.create(%{@valid_attrs | name: name})
      assert {:ok, _} = HeartbeatConfig.delete_config(config)
      assert HeartbeatConfig.get(config.id) == nil
    end
  end
end
