defmodule Synapsis.AgentConfigSeedTest do
  use ExUnit.Case, async: false

  alias Synapsis.AgentConfigs
  alias Synapsis.Config.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_dir = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "private-config")
    File.mkdir_p!(config_dir)
    File.chmod!(config_dir, 0o700)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)
    File.write!(Store.file_path(:agent), "")
    assert :ok = Store.reload(:agent)

    on_exit(fn ->
      if previous_dir,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous_dir),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      Store.reload(:agent)
    end)

    :ok
  end

  test "creates only the missing main default and repeated startup preserves it" do
    assert :ok = AgentConfigs.seed_defaults()
    assert [main] = Store.list(:agent)
    assert main["name"] == "main"
    assert main["is_default"] == true
    assert is_binary(main["id"])

    assert :ok = AgentConfigs.seed_defaults()
    assert :ok = Store.reload(:agent)
    assert Store.list(:agent) == [main]
  end

  for {name, attrs} <- [
        {"assistant", %{"is_default" => true}},
        {"build", %{"is_default" => false, "tool_contract_version" => 0, "tools" => []}},
        {"plan", %{"is_default" => true, "tool_contract_version" => 1}},
        {"reviewer", %{"is_default" => false, "tool_contract_version" => 1}}
      ] do
    test "startup preserves the entire saved #{name} record while creating main" do
      raw = put_saved_agent(unquote(name), unquote(Macro.escape(attrs)))

      assert :ok = AgentConfigs.seed_defaults()
      assert {:ok, ^raw} = Store.get(:agent, raw["id"])
      assert AgentConfigs.get_by_name("main").is_default

      assert Enum.sort(Enum.map(Store.list(:agent), & &1["name"])) ==
               Enum.sort([unquote(name), "main"])

      seeded = Map.new(Store.list(:agent), &{&1["id"], &1})
      assert :ok = AgentConfigs.seed_defaults()
      assert :ok = Store.reload(:agent)
      assert Map.new(Store.list(:agent), &{&1["id"], &1}) == seeded
      assert {:ok, ^raw} = Store.get(:agent, raw["id"])
    end
  end

  for {version_label, attrs} <- [
        {"missing", %{}},
        {"legacy", %{"tool_contract_version" => 0, "tools" => []}},
        {"native", %{"tool_contract_version" => 1}}
      ] do
    test "startup only marks existing main default with #{version_label} contract version" do
      raw = put_saved_agent("main", unquote(Macro.escape(attrs)))
      expected = Map.put(raw, "is_default", true)

      assert :ok = AgentConfigs.seed_defaults()
      assert Store.list(:agent) == [expected]
      assert AgentConfigs.get_by_name("main").is_default

      assert :ok = AgentConfigs.seed_defaults()
      assert :ok = Store.reload(:agent)
      assert Store.list(:agent) == [expected]
    end
  end

  test "startup preserves an already-default main without filling omitted fields" do
    raw = %{
      "id" => Ecto.UUID.generate(),
      "name" => "main",
      "is_default" => true,
      "future_setting" => %{"keep" => ["one", "two"]}
    }

    assert {:ok, ^raw} = Store.put(:agent, raw)
    assert :ok = AgentConfigs.seed_defaults()
    assert :ok = Store.reload(:agent)
    assert Store.list(:agent) == [raw]
  end

  defp put_saved_agent(name, attrs) do
    first_toolset = Ecto.UUID.generate()

    raw =
      Map.merge(
        %{
          "id" => Ecto.UUID.generate(),
          "name" => name,
          "label" => "Saved #{name}",
          "provider" => "saved-provider",
          "model" => "saved-model",
          "system_prompt" => "Keep the saved instructions.",
          "tools" => ["send_message", "synapsis::file_read", "send_message"],
          "toolset_id" => Ecto.UUID.generate(),
          "toolset_ids" => [first_toolset, Ecto.UUID.generate(), first_toolset],
          "is_default" => false,
          "enabled" => false,
          "config" => Jason.encode!(%{"nested_unknown" => %{"keep" => ["one", "two"]}}),
          "future_setting" => %{"nested" => ["keep", "order"]}
        },
        attrs
      )

    assert {:ok, ^raw} = Store.put(:agent, raw)
    raw
  end
end
