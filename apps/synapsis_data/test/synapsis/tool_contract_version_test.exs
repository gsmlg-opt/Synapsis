defmodule Synapsis.ToolContractVersionTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{AgentConfig, AgentConfigs, SessionPermission, Toolset, Toolsets}
  alias Synapsis.Config.Store
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @config_types [:agent, :toolset]

  setup %{tmp_dir: tmp_dir} do
    previous_dir = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "private-config")
    File.mkdir_p!(config_dir)
    File.chmod!(config_dir, 0o700)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)

    for type <- @config_types do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

    on_exit(fn ->
      if previous_dir,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous_dir),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      Enum.each(@config_types, &Store.reload/1)
    end)

    :ok
  end

  test "all typed records default missing versions to legacy zero and support only zero and one" do
    cases = [
      {AgentConfig, %{name: "version-agent"}},
      {Toolset, %{name: "version-toolset"}},
      {SessionPermission, %{session_id: Ecto.UUID.generate()}}
    ]

    for {module, attrs} <- cases do
      changeset = module.changeset(struct(module), attrs)
      assert changeset.valid?
      assert get_field(changeset, :tool_contract_version) == 0

      for version <- [0, 1] do
        changeset =
          module.changeset(struct(module), Map.put(attrs, :tool_contract_version, version))

        assert changeset.valid?
        assert get_field(changeset, :tool_contract_version) === version
      end

      for version <- [-1, 2, nil, "native"] do
        changeset =
          module.changeset(struct(module), Map.put(attrs, :tool_contract_version, version))

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :tool_contract_version)
      end
    end
  end

  test "agent create, reload and update preserve the typed version and exact stored selections" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete(:agent, id) end)

    assert {:ok, agent} =
             AgentConfigs.create(%{
               id: id,
               name: "version-agent-#{id}",
               tools: ["send_message", "synapsis::file_read"],
               toolset_ids: [Ecto.UUID.generate(), Ecto.UUID.generate()],
               tool_contract_version: 1
             })

    assert Map.fetch!(agent, :tool_contract_version) === 1
    assert {:ok, stored} = Store.get(:agent, id)
    assert stored["tool_contract_version"] === 1
    assert stored["tools"] == agent.tools
    assert stored["toolset_ids"] == agent.toolset_ids
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(id) == agent

    assert {:ok, updated} = AgentConfigs.update(agent, %{tools: [], tool_contract_version: 0})
    assert Map.fetch!(updated, :tool_contract_version) === 0
    assert AgentConfigs.get(id).tools == []
    assert {:ok, stored} = Store.get(:agent, id)
    assert stored["tool_contract_version"] === 0
  end

  test "toolset create, reload and update preserve the typed version and explicit empty list" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete(:toolset, id) end)

    assert {:ok, toolset} =
             Toolsets.create(%{
               id: id,
               name: "version-toolset-#{id}",
               tool_names: ["send_message", "synapsis::file_read"],
               tool_contract_version: 1
             })

    assert Map.fetch!(toolset, :tool_contract_version) === 1
    assert {:ok, stored} = Store.get(:toolset, id)
    assert stored["tool_contract_version"] === 1
    assert stored["tool_names"] == toolset.tool_names
    assert :ok = Store.reload(:toolset)
    assert Toolsets.get(id) == toolset

    assert {:ok, updated} = Toolsets.update(toolset, %{tool_names: [], tool_contract_version: 0})
    assert Map.fetch!(updated, :tool_contract_version) === 0
    assert Toolsets.get(id).tool_names == []
    assert {:ok, stored} = Store.get(:toolset, id)
    assert stored["tool_contract_version"] === 0
  end

  test "legacy stored agent and toolset entries remain version zero without translating names" do
    for {type, context, names_key} <- [
          {:agent, AgentConfigs, "tools"},
          {:toolset, Toolsets, "tool_names"}
        ] do
      id = Ecto.UUID.generate()
      on_exit(fn -> Store.delete(type, id) end)
      raw = %{"id" => id, "name" => "legacy-#{id}", names_key => ["send_message", "bash"]}
      assert {:ok, ^raw} = Store.put(type, raw)
      record = context.get(id)
      assert Map.fetch!(record, :tool_contract_version) === 0
      assert Map.fetch!(record, String.to_existing_atom(names_key)) == raw[names_key]
      assert {:ok, ^raw} = Store.get(type, id)
    end
  end

  test "session permission typed version survives the existing generic session-value roundtrip" do
    session_id = Ecto.UUID.generate()
    on_exit(fn -> SessionStore.delete_session(session_id) end)

    changeset =
      SessionPermission.changeset(%SessionPermission{}, %{
        session_id: session_id,
        tool_contract_version: 1,
        tool_overrides: %{"send_message" => "deny"}
      })

    assert changeset.valid?
    permission = apply_changes(changeset)
    assert Map.fetch!(permission, :tool_contract_version) === 1
    assert :ok = SessionStore.put_value(session_id, "permission", Map.from_struct(permission))
    stored = SessionStore.get_value(session_id, "permission")
    assert stored.tool_contract_version === 1

    reloaded = SessionPermission.changeset(%SessionPermission{}, stored) |> apply_changes()
    assert reloaded == permission
    assert reloaded.tool_overrides == %{"send_message" => "deny"}
  end

  for {type, context, names_key} <- [
        {:agent, AgentConfigs, "tools"},
        {:toolset, Toolsets, "tool_names"}
      ] do
    concurrent_change =
      if type == :agent, do: %{"model" => "fresh-model"}, else: %{"name" => "fresh-name"}

    test "#{type} metadata updates preserve exact native selections and every untouched raw field" do
      type = unquote(type)
      context = unquote(context)
      raw = put_native(type, unquote(names_key))

      assert {:ok, updated} = context.update(context.get(raw["id"]), %{description: "edited"})
      assert updated.description == "edited"
      assert updated.tool_contract_version === 1
      assert {:ok, stored} = Store.get(type, raw["id"])
      assert stored == Map.put(raw, "description", "edited")
      assert :ok = Store.reload(type)
      assert {:ok, ^stored} = Store.get(type, raw["id"])
      assert context.get(raw["id"]) == updated
    end

    test "#{type} stale legacy structs cannot overwrite a later native migration" do
      type = unquote(type)
      context = unquote(context)
      names_key = unquote(names_key)
      raw = put_native(type, names_key)

      legacy =
        Map.merge(raw, %{names_key => ["send_message", "file_read"], "tool_contract_version" => 0})

      assert {:ok, ^legacy} = Store.put(type, legacy)
      stale = context.get(raw["id"])

      migration = %{names_key => raw[names_key], "tool_contract_version" => 1}
      assert {:ok, ^raw} = Store.merge_existing(type, raw["id"], migration)

      assert {:ok, updated} = context.update(stale, %{description: "after migration"})
      assert updated.tool_contract_version === 1
      assert Map.fetch!(updated, String.to_existing_atom(names_key)) == raw[names_key]
      assert {:ok, stored} = Store.get(type, raw["id"])
      assert stored == Map.put(raw, "description", "after migration")
    end

    test "#{type} omitted known fields use the current record after a concurrent write" do
      type = unquote(type)
      context = unquote(context)
      raw = put_native(type, unquote(names_key))
      stale = context.get(raw["id"])
      owner = self()
      known = unquote(Macro.escape(concurrent_change))

      task =
        Store.with_write_lock(fn ->
          task =
            Task.async(fn ->
              send(owner, :update_started)
              context.update(stale, %{description: "concurrent edit"})
            end)

          assert_receive :update_started
          assert {:ok, _} = Store.merge_existing(type, raw["id"], known)
          task
        end)

      assert {:ok, updated} = Task.await(task)
      assert {:ok, stored} = Store.get(type, raw["id"])
      assert stored == raw |> Map.merge(known) |> Map.put("description", "concurrent edit")
      assert context.get(raw["id"]) == updated
    end

    test "#{type} explicit selections and versions remain editable while unknown incoming attrs are ignored" do
      type = unquote(type)
      context = unquote(context)
      names_key = unquote(names_key)
      raw = put_native(type, names_key)
      stale = context.get(raw["id"])
      attrs = %{names_key => [], "tool_contract_version" => 0, "future_setting" => "overwrite"}

      assert {:ok, updated} = context.update(stale, attrs)
      assert updated.tool_contract_version === 0
      assert Map.fetch!(updated, String.to_existing_atom(names_key)) == []
      assert {:ok, stored} = Store.get(type, raw["id"])
      assert stored == Map.merge(raw, %{names_key => [], "tool_contract_version" => 0})

      attrs = %{
        names_key => ["send_message", "synapsis::file_read"],
        "tool_contract_version" => 1
      }

      assert {:ok, updated} = context.update(updated, attrs)
      assert updated.tool_contract_version === 1
      assert {:ok, stored} = Store.get(type, raw["id"])
      assert stored == Map.merge(raw, attrs)
    end

    test "#{type} updates of deleted records return not_found without recreating them" do
      type = unquote(type)
      context = unquote(context)
      raw = put_native(type, unquote(names_key))
      stale = context.get(raw["id"])
      assert :ok = Store.delete(type, raw["id"])
      before = File.read!(Store.file_path(type))

      assert {:error, :not_found} = context.update(stale, %{description: "resurrect"})
      assert {:error, :not_found} = Store.get(type, raw["id"])
      assert File.read!(Store.file_path(type)) == before
    end

    for {id_key, description_key, key_label} <- [
          {:id, :description, "atom"},
          {"id", "description", "string"}
        ] do
      test "#{type} ignores invalid-type and different valid #{key_label} IDs in update attrs" do
        type = unquote(type)
        context = unquote(context)
        raw = put_native(type, unquote(names_key))
        record = context.get(raw["id"])

        for incoming_id <- [123, Ecto.UUID.generate()] do
          description = "metadata-#{incoming_id}"
          attrs = %{unquote(id_key) => incoming_id, unquote(description_key) => description}

          assert {:ok, updated} = context.update(record, attrs)
          assert updated.id == raw["id"]
          assert updated.description == description
          assert {:ok, stored} = Store.get(type, raw["id"])
          assert stored == Map.put(raw, "description", description)
          assert {:error, :not_found} = Store.get(type, incoming_id)
          assert Enum.map(Store.list(type), & &1["id"]) == [raw["id"]]
          assert :ok = Store.reload(type)
          assert context.get(raw["id"]) == updated
        end
      end
    end

    test "#{type} validation failures preserve the complete current raw record" do
      type = unquote(type)
      context = unquote(context)
      raw = put_native(type, unquote(names_key))
      before = File.read!(Store.file_path(type))

      assert {:error, %Ecto.Changeset{valid?: false}} =
               context.update(context.get(raw["id"]), %{tool_contract_version: 2})

      assert {:ok, ^raw} = Store.get(type, raw["id"])
      assert File.read!(Store.file_path(type)) == before
    end

    test "#{type} persistence failures propagate without changing current raw data" do
      type = unquote(type)
      context = unquote(context)
      raw = put_native(type, unquote(names_key))
      before = File.read!(Store.file_path(type))
      File.chmod!(Store.file_path(type), 0o400)

      assert {:error, {:persist_failed, _reason}} =
               context.update(context.get(raw["id"]), %{description: "cannot persist"})

      assert {:ok, ^raw} = Store.get(type, raw["id"])
      assert File.read!(Store.file_path(type)) == before
    end
  end

  test "agent explicit config edits preserve JSON encoding and explicit empty links" do
    raw = put_native(:agent, "tools")
    config = %{"replacement" => %{"enabled" => true}}

    assert {:ok, updated} =
             AgentConfigs.update(AgentConfigs.get(raw["id"]), %{
               config: config,
               toolset_ids: [],
               toolset_id: nil
             })

    assert updated.config == config
    assert updated.toolset_ids == []
    assert updated.toolset_id == nil
    assert {:ok, stored} = Store.get(:agent, raw["id"])
    assert is_binary(stored["config"])
    assert Jason.decode!(stored["config"]) == config
    assert stored["toolset_ids"] == []
    assert stored["toolset_id"] == nil
    assert stored["future_setting"] == raw["future_setting"]
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(raw["id"]) == updated
  end

  defp put_native(type, names_key) do
    id = Ecto.UUID.generate()

    raw = %{
      "id" => id,
      "name" => "preserve-#{id}",
      "description" => "original",
      names_key => ["send_message", "synapsis::file_read", "send_message"],
      "tool_contract_version" => 1,
      "future_setting" => %{"nested" => ["keep", "order"]}
    }

    raw =
      if type == :agent do
        Map.merge(raw, %{
          "toolset_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()],
          "toolset_id" => Ecto.UUID.generate(),
          "config" => Jason.encode!(%{"nested_unknown" => %{"keep" => ["one", "two"]}})
        })
      else
        raw
      end

    assert {:ok, ^raw} = Store.put(type, raw)
    raw
  end
end
