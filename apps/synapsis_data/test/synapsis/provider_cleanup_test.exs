defmodule Synapsis.ProviderCleanupTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{Config.Store, MCPConfigs, Models, Skills}

  @types [:provider, :model, :backplane, :mcp, :skill, :agent, :toolset]

  setup do
    Enum.each(@types, &clear_config_store/1)
    on_exit(fn -> Enum.each(@types, &clear_config_store/1) end)
    :ok
  end

  test "provider deletion removes linked records and references while preserving independent configs" do
    data = linked_configs()

    assert {:ok, removed} = Store.delete_provider(data.provider["id"])
    assert removed.provider == data.provider
    assert Enum.map(removed.models, & &1["id"]) == [data.model["id"]]
    assert Enum.map(removed.sources, & &1["id"]) == ["source"]
    assert Enum.map(removed.mcps, & &1["id"]) == ["mcp"]
    assert Enum.map(removed.skills, & &1["id"]) == ["remote-skill"]

    for {type, id} <- [
          provider: data.provider["id"],
          model: data.model["id"],
          backplane: "source",
          mcp: "mcp",
          skill: "remote-skill"
        ] do
      assert {:error, :not_found} = Store.get(type, id)
    end

    assert {:ok, agent} = Store.get(:agent, "agent")
    refute agent["provider"]
    refute agent["model"]
    assert agent["fallback_models"] == "other/safe"
    assert agent["tools"] == ["file_read", "mcp:independent:keep"]
    assert agent["config"]["skill_ids"] == ["local-skill"]
    assert agent["config"]["mcp_selection"]["sources"] == %{"independent" => %{"mode" => "all"}}
    assert agent["config"]["preserved"] == true

    assert {:ok, %{"tool_names" => ["file_read", "mcp:independent:keep"]}} =
             Store.get(:toolset, "toolset")

    assert {:ok, %{"tool_allowlist" => ["file_read"]}} = Store.get(:skill, "local-skill")
    assert {:ok, _} = Store.get(:mcp, "independent")
    assert {:ok, _} = Store.get(:backplane, "independent-source")

    replacement = %{data.provider | "id" => Ecto.UUID.generate()}
    assert {:ok, _} = Store.put(:provider, replacement)
    assert {:ok, []} = Models.list(provider_id: replacement["id"])
    assert {:ok, reloaded} = Store.get(:agent, "agent")
    refute reloaded["provider"]
  end

  test "failed cleanup preserves the provider and reports failure for retry" do
    data = linked_configs()
    File.chmod!(Store.file_path(:model), 0o400)

    assert {:error, _reason} = Store.delete_provider(data.provider["id"])
    assert {:ok, _} = Store.get(:provider, data.provider["id"])
    File.chmod!(Store.file_path(:model), 0o600)
    assert {:ok, _} = Store.delete_provider(data.provider["id"])
  end

  test "typed agent JSON assignments are cleaned without changing unrelated config" do
    data = linked_configs()

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "typed-agent",
               provider: "backplane",
               model: "main-model",
               config: %{
                 "skill_ids" => ["remote-skill", "local-skill"],
                 "preserved" => true,
                 "mcp_selection" => %{
                   "default" => "all",
                   "sources" => %{"mcp" => %{"mode" => "all"}}
                 }
               }
             })

    assert {:ok, _} = Store.delete_provider(data.provider["id"])
    cleaned = Synapsis.AgentConfigs.get(agent.id)
    refute cleaned.provider
    refute cleaned.model
    assert cleaned.config["skill_ids"] == ["local-skill"]
    assert cleaned.config["mcp_selection"]["sources"] == %{}
    assert cleaned.config["preserved"] == true
  end

  test "a late partial cleanup failure keeps the provider retryable and exposes the initial dependencies" do
    data = linked_configs()
    assert {:ok, initial} = Store.provider_dependencies(data.provider["id"])
    assert Enum.map(initial.mcps, & &1["id"]) == ["mcp"]
    File.chmod!(Store.file_path(:backplane), 0o400)

    assert {:error, {:provider_cleanup_failed, :backplane, "source", _}} =
             Store.delete_provider(data.provider["id"])

    assert {:ok, _} = Store.get(:provider, data.provider["id"])
    assert {:ok, remaining} = Store.provider_dependencies(data.provider["id"])
    assert remaining.mcps == []
    assert remaining.models == []
    assert remaining.skills == []
    assert Enum.map(remaining.sources, & &1["id"]) == ["source"]

    File.chmod!(Store.file_path(:backplane), 0o600)
    assert {:ok, _} = Store.delete_provider(data.provider["id"])
    assert {:error, :not_found} = Store.get(:provider, data.provider["id"])
  end

  test "late imports and source writes cannot restore deleted provider associations" do
    data = linked_configs()
    assert {:ok, _} = Store.delete_provider(data.provider["id"])

    assert {:error, _} = Models.import(data.provider["id"], [%{id: "late"}])
    assert {:error, _} = Store.put(:model, data.model)
    assert {:error, _} = Store.put(:backplane, data.source)
    assert {:error, _} = Store.put(:mcp, data.mcp)
    assert {:error, _} = Store.put(:skill, data.skill)
    assert {:error, :not_found} = Store.get(:mcp, "mcp")
  end

  test "stale typed MCP and skill updates never recreate deleted records" do
    assert {:ok, mcp} =
             MCPConfigs.create(%{name: "standalone", transport: "stdio", command: "test"})

    assert {:ok, skill} = Skills.create(%{name: "standalone"})
    assert {:ok, _} = MCPConfigs.delete(mcp)
    assert {:ok, _} = Skills.delete(skill)
    assert {:error, :not_found} = MCPConfigs.update(mcp, %{name: "late"})
    assert {:error, :not_found} = Skills.update(skill, %{name: "late"})
  end

  test "historical orphan models remain readable on reload but new orphan writes fail" do
    provider_id = Ecto.UUID.generate()
    id = Ecto.UUID.generate()

    content =
      "[[models]]\nid = #{inspect(id)}\nprovider_id = #{inspect(provider_id)}\nmodel = \"legacy\"\ncontext_window = 256000\nenabled = true\n"

    File.write!(Store.file_path(:model), content)
    assert :ok = Store.reload(:model)
    assert {:ok, _} = Models.get(id)
    assert {:error, _} = Models.create(%{provider_id: provider_id, model: "new-orphan"})
  end

  test "the local write lock is reentrant and excludes concurrent imports during cleanup" do
    data = linked_configs()
    parent = self()

    task =
      Store.with_write_lock(fn ->
        assert :nested = Store.with_write_lock(fn -> :nested end)

        task =
          Task.async(fn ->
            send(parent, :import_started)
            Models.import(data.provider["id"], [%{id: "concurrent"}])
          end)

        assert_receive :import_started
        assert {:ok, _} = Store.delete_provider(data.provider["id"])
        task
      end)

    assert {:error, _} = Task.await(task)
    assert {:ok, []} = Models.list(provider_id: data.provider["id"])
  end

  defp linked_configs do
    provider = %{"id" => Ecto.UUID.generate(), "name" => "backplane", "enabled" => true}
    source = %{"id" => "source", "name" => "linked", "provider_id" => provider["id"]}

    model = %{
      "id" => Ecto.UUID.generate(),
      "provider_id" => provider["id"],
      "model" => "main-model",
      "context_window" => 256_000,
      "enabled" => true
    }

    mcp = %{
      "id" => "mcp",
      "name" => "linked-mcp",
      "provider_id" => provider["id"],
      "config" => %{"backplane_source_id" => "source"}
    }

    skill = %{
      "id" => "remote-skill",
      "name" => "remote",
      "config_overrides" => %{"backplane_source_id" => "source"}
    }

    entries = [
      provider: provider,
      backplane: source,
      model: model,
      mcp: mcp,
      skill: skill,
      backplane: %{"id" => "independent-source", "name" => "independent"},
      mcp: %{"id" => "independent", "name" => "independent"},
      skill: %{
        "id" => "local-skill",
        "name" => "local",
        "tool_allowlist" => ["file_read", "mcp:linked-mcp:old"]
      },
      agent: %{
        "id" => "agent",
        "name" => "main",
        "provider" => "backplane",
        "model" => "main-model",
        "fallback_models" => "backplane/fallback,implicit,other/safe",
        "tools" => ["file_read", "mcp:linked-mcp:old", "mcp:independent:keep"],
        "config" => %{
          "preserved" => true,
          "skill_ids" => ["remote-skill", "local-skill"],
          "mcp_selection" => %{
            "default" => "all",
            "sources" => %{"mcp" => %{"mode" => "all"}, "independent" => %{"mode" => "all"}}
          }
        }
      },
      toolset: %{
        "id" => "toolset",
        "tool_names" => ["file_read", "mcp:linked-mcp:old", "mcp:independent:keep"]
      }
    ]

    Enum.each(entries, fn {type, entry} -> assert {:ok, _} = Store.put(type, entry) end)
    %{provider: provider, source: source, model: model, mcp: mcp, skill: skill}
  end
end
