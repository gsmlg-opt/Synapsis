defmodule Synapsis.Agent.ResolverTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Resolver
  alias Synapsis.{AgentConfigs, AgentSkills, Config.Store, Skills, Toolsets}

  setup do
    Synapsis.Session.Store.ensure_started()
    # ADR-006 C4: clean up any existing agent configs (Config.Store) for isolation.
    clear_agent_configs()
    on_exit(&clear_agent_configs/0)
    :ok
  end

  defp clear_agent_configs do
    Enum.each(Store.list(:agent), &Store.delete(:agent, &1["id"]))
  end

  describe "resolve/1 with no DB records (hardcoded fallback)" do
    test "returns default main agent config" do
      agent = Resolver.resolve("main")
      assert agent.name == "main"
      assert agent.read_only == false
      assert agent.reasoning_effort == "medium"
      assert agent.permission_mode == "yolo"
      assert agent.max_tokens == 8192
      assert agent.model == nil
      assert agent.provider == nil
      assert is_binary(agent.system_prompt)
      assert String.length(agent.system_prompt) > 0
    end

    test "returns proper structure with all expected keys" do
      agent = Resolver.resolve("main")

      assert Map.has_key?(agent, :name)
      assert Map.has_key?(agent, :model)
      assert Map.has_key?(agent, :provider)
      assert Map.has_key?(agent, :system_prompt)
      assert Map.has_key?(agent, :tools)
      assert Map.has_key?(agent, :reasoning_effort)
      assert Map.has_key?(agent, :permission_mode)
      assert Map.has_key?(agent, :read_only)
      assert Map.has_key?(agent, :max_tokens)
      assert Map.has_key?(agent, :model_tier)
      assert Map.has_key?(agent, :workspace_path)
      assert agent.workspace_path == "~/.synapsis/agents/main"
    end

    test "default main agent includes all expected tools" do
      agent = Resolver.resolve("main")

      for tool <- ~w(
        synapsis::read synapsis::write synapsis::edit synapsis::ls
        apply_patch exec_command write_stdin
        synapsis::todo_read synapsis::todo_write
        spawn_agent wait_agent synapsis::skill synapsis::ask_user
        synapsis::memory_save synapsis::memory_source_search synapsis::session_summarize
      ) do
        assert tool in agent.tools, "expected #{tool} in main agent tools"
      end

      for retired_tool <- ~w(
        workspace_read workspace_write workspace_delete workspace_list workspace_search
        notebook_read notebook_edit
        fetch web_search
      ) do
        refute retired_tool in agent.tools, "expected #{retired_tool} to be removed"
      end
    end

    test "retired and unknown agent names fall back to main agent defaults" do
      agent = Resolver.resolve("unknown_agent_xyz")
      main = Resolver.resolve("main")

      for retired_name <- ~w(assistant build plan) do
        retired = Resolver.resolve(retired_name)
        assert retired.name == "main"
        assert retired.tools == main.tools
        assert retired.read_only == main.read_only
        assert retired.system_prompt == main.system_prompt
        assert retired.max_tokens == main.max_tokens
      end

      assert agent.name == "main"
      assert agent.tools == main.tools
      assert agent.read_only == main.read_only
      assert agent.system_prompt == main.system_prompt
      assert agent.max_tokens == main.max_tokens
    end

    test "accepts atom agent names" do
      agent = Resolver.resolve(:build)
      assert agent.name == "main"
      assert agent.read_only == false
    end

    test "main agent has :default model_tier" do
      agent = Resolver.resolve("main")
      assert agent.model_tier == :default
    end

    test "default agent fills main provider and model" do
      agent =
        Resolver.resolve("main", %{
          "agents" => %{
            "default" => %{
              "provider" => "zhipu-coding",
              "model" => "glm-4.7"
            }
          }
        })

      assert agent.provider == "zhipu-coding"
      assert agent.model == "glm-4.7"
    end
  end

  describe "resolve/1 with DB records" do
    test "loads agent config from database" do
      {:ok, _} =
        AgentConfigs.create(%{
          name: "build",
          provider: "anthropic",
          model: "claude-opus-4-20250514",
          system_prompt: "Custom prompt",
          tools: ["file_read", "grep"],
          reasoning_effort: "high",
          permission_mode: "restrict",
          read_only: false,
          max_tokens: 4096,
          model_tier: "fast"
        })

      agent = Resolver.resolve("build")
      assert agent.name == "build"
      assert agent.provider == "anthropic"
      assert agent.model == "claude-opus-4-20250514"
      assert agent.system_prompt == "Custom prompt"
      assert agent.tools == ["file_read", "grep"]
      assert agent.reasoning_effort == "high"
      assert agent.permission_mode == "restrict"
      assert agent.max_tokens == 4096
      assert agent.model_tier == :fast
    end

    test "DB record takes precedence over hardcoded defaults" do
      {:ok, _} =
        AgentConfigs.create(%{
          name: "plan",
          provider: "openai",
          model: "gpt-4",
          reasoning_effort: "low",
          read_only: false,
          max_tokens: 2048,
          model_tier: "default"
        })

      agent = Resolver.resolve("plan")
      assert agent.provider == "openai"
      assert agent.model == "gpt-4"
      assert agent.reasoning_effort == "low"
      assert agent.read_only == false
      assert agent.max_tokens == 2048
      assert agent.model_tier == :default
    end

    test "project default agent fills blank DB provider and model" do
      {:ok, _} =
        AgentConfigs.create(%{
          name: "main",
          provider: nil,
          model: nil
        })

      agent =
        Resolver.resolve("main", %{
          "agents" => %{
            "default" => %{
              "provider" => "zhipu-coding",
              "model" => "glm-4.7"
            }
          }
        })

      assert agent.provider == "zhipu-coding"
      assert agent.model == "glm-4.7"
    end

    test "custom agent stored in DB is resolved" do
      {:ok, _} =
        AgentConfigs.create(%{
          name: "reviewer",
          label: "Code Reviewer",
          icon: "magnify",
          description: "Reviews code for quality",
          provider: "anthropic",
          model: "claude-opus-4-20250514",
          system_prompt: "You are a code reviewer.",
          tools: ["file_read", "grep", "glob"],
          reasoning_effort: "high",
          permission_mode: "yolo",
          read_only: true,
          max_tokens: 16384,
          model_tier: "expert"
        })

      agent = Resolver.resolve("reviewer")
      assert agent.name == "reviewer"
      assert agent.label == "Code Reviewer"
      assert agent.icon == "magnify"
      assert agent.description == "Reviews code for quality"
      assert agent.provider == "anthropic"
      assert agent.permission_mode == "yolo"
      assert agent.read_only == true
      assert agent.model_tier == :expert
    end

    test "uses assigned toolset tools before legacy agent tools" do
      {:ok, toolset} =
        Toolsets.create(%{
          name: "focused-tools",
          tool_names: ["file_read", "mcp:filesystem:read_file"]
        })

      {:ok, _} =
        AgentConfigs.create(%{
          name: "toolset-agent",
          tools: ["bash"],
          toolset_id: toolset.id
        })

      agent = Resolver.resolve("toolset-agent")
      assert agent.tools == ["file_read", "mcp:filesystem:read_file"]
      assert agent.toolset_id == toolset.id
      assert agent.toolset_ids == [toolset.id]
    end

    test "preserves unavailable saved tools for explicit migration rather than silently deleting them" do
      {:ok, toolset} =
        Toolsets.create(%{
          name: "retired-toolset",
          tool_names: ["workspace_read", "file_read", "notebook_edit"]
        })

      {:ok, _} =
        AgentConfigs.create(%{
          name: "retired-tool-agent",
          tools: ["workspace_write", "bash", "notebook_read"],
          toolset_id: toolset.id
        })

      agent = Resolver.resolve("retired-tool-agent")
      assert agent.tools == ["workspace_read", "file_read", "notebook_edit"]

      {:ok, _} = AgentConfigs.create(%{name: "direct-unavailable", tools: ["workspace_write"]})
      assert Resolver.resolve("direct-unavailable").tools == ["workspace_write"]
    end

    test "an explicitly selected empty toolset never falls back to agent tools" do
      {:ok, toolset} =
        Toolsets.create(%{name: "empty-selection", tool_names: [], tool_contract_version: 1})

      {:ok, _} =
        AgentConfigs.create(%{
          name: "empty-toolset-agent",
          tools: ["bash"],
          toolset_ids: [toolset.id]
        })

      agent = Resolver.resolve("empty-toolset-agent")
      assert agent.tools == []
      refute Map.has_key?(agent, :tool_selection_error)
    end

    test "missing selected toolsets remain visible errors even when another selected set exists" do
      {:ok, toolset} = Toolsets.create(%{name: "existing-selection", tool_names: ["file_read"]})
      missing = Ecto.UUID.generate()

      {:ok, _} =
        AgentConfigs.create(%{
          name: "missing-toolset-agent",
          tools: ["bash"],
          toolset_ids: [toolset.id, missing]
        })

      agent = Resolver.resolve("missing-toolset-agent")
      assert agent.tool_selection_error == {:toolsets_unavailable, [missing]}
      assert agent.tools == []
      assert agent.toolset_ids == [toolset.id, missing]
    end

    test "merges tools from multiple assigned toolsets in order" do
      {:ok, readers} =
        Toolsets.create(%{
          name: "readers",
          tool_names: ["file_read", "grep"]
        })

      {:ok, docs} =
        Toolsets.create(%{
          name: "docs",
          tool_names: ["mcp:docs:search", "grep"]
        })

      {:ok, _} =
        AgentConfigs.create(%{
          name: "multi-toolset-agent",
          tools: ["bash"],
          toolset_ids: [docs.id, readers.id],
          toolset_id: docs.id
        })

      agent = Resolver.resolve("multi-toolset-agent")
      assert agent.tools == ["mcp:docs:search", "grep", "file_read"]
      assert agent.toolset_ids == [docs.id, readers.id]
    end

    test "returns skills assigned to the agent" do
      {:ok, agent_config} =
        AgentConfigs.create(%{
          name: "skilled-agent",
          system_prompt: "Base prompt"
        })

      {:ok, skill} =
        Skills.create(%{
          name: "review-style",
          scope: "global",
          system_prompt_fragment: "Always review tradeoffs."
        })

      assert {:ok, _} = Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

      {:ok, unavailable} =
        Skills.create(%{
          name: "unavailable-review-style",
          scope: "global",
          system_prompt_fragment: "This must not enter context.",
          config_overrides: %{
            "managed_by" => "backplane",
            "backplane_source_id" => "source-1",
            "backplane_available" => false
          }
        })

      {:ok, disabled} =
        Skills.create(%{
          name: "disabled-review-style",
          scope: "global",
          system_prompt_fragment: "This must not enter context either.",
          enabled: false
        })

      {:ok, _skills} =
        AgentSkills.assign_skills(agent_config, [skill.id, unavailable.id, disabled.id])

      agent = Resolver.resolve("skilled-agent")
      assert Enum.map(agent.skills, & &1.name) == ["review-style"]
      assert hd(agent.skills).system_prompt_fragment == "Always review tradeoffs."
      assert [%Synapsis.SkillCatalog.Entry{} = entry] = agent.skill_catalog
      assert entry.locator == "synapsis://skills/#{skill.id}"
      assert entry.name == "review-style"

      assert AgentSkills.list_skill_ids(agent_config.id) == [
               skill.id,
               unavailable.id,
               disabled.id
             ]
    end

    test "returns configured agent workspace path" do
      {:ok, _} =
        AgentConfigs.create(%{
          name: "workspace-agent",
          config: %{"workspace_path" => "~/.synapsis/agents/custom-workspace"}
        })

      agent = Resolver.resolve("workspace-agent")
      assert agent.workspace_path == "~/.synapsis/agents/custom-workspace"
    end
  end

  describe "native contract version admission" do
    @describetag :contract_version

    test "direct native selection requires explicit integer version 1 even when empty" do
      for {version, suffix} <- [
            {0, "legacy"},
            {nil, "missing"},
            {"1", "string"},
            {2, "future"},
            {1.0, "float"}
          ],
          names <- [["send_message"], []] do
        {:ok, saved} =
          AgentConfigs.create(%{name: "version-#{suffix}-#{length(names)}", tools: names})

        assert {:ok, raw} = Store.get(:agent, saved.id)

        raw =
          if is_nil(version),
            do: Map.delete(raw, "tool_contract_version"),
            else: Map.put(raw, "tool_contract_version", version)

        assert {:ok, _} = Store.put(:agent, raw)

        resolved = Resolver.resolve(saved.name)
        assert Map.has_key?(resolved, :tool_selection_error)
        refute resolved[:tool_contract_version] === 1
        assert {:ok, ^raw} = Store.get(:agent, saved.id)
      end
    end

    test "native same-spelled names and explicit empty selection admit only version 1" do
      for names <- [["send_message"], []] do
        {:ok, saved} =
          AgentConfigs.create(%{
            name: "native-version-#{length(names)}",
            tools: names,
            tool_contract_version: 1
          })

        resolved = Resolver.resolve(saved.name)
        assert resolved.tools == names
        assert resolved.tool_contract_version === 1
        refute Map.has_key?(resolved, :tool_selection_error)
      end
    end

    test "every active toolset supplies the contract version instead of the overridden agent" do
      {:ok, first} =
        Toolsets.create(%{
          name: "version-native-first",
          tool_names: ["send_message"],
          tool_contract_version: 1
        })

      {:ok, empty} =
        Toolsets.create(%{name: "version-native-empty", tool_names: [], tool_contract_version: 1})

      {:ok, inactive} =
        Toolsets.create(%{
          name: "version-inactive-legacy",
          tool_names: ["bash"],
          tool_contract_version: 0
        })

      on_exit(fn -> Enum.each([first, empty, inactive], &Toolsets.delete/1) end)

      {:ok, saved} =
        AgentConfigs.create(%{
          name: "legacy-agent-native-toolsets",
          tools: ["bash"],
          toolset_id: inactive.id,
          toolset_ids: [first.id, empty.id],
          tool_contract_version: 0
        })

      assert {:ok, raw} = Store.get(:agent, saved.id)
      resolved = Resolver.resolve(saved.name)
      assert resolved.tools == ["send_message"]
      assert resolved.tool_contract_version === 1
      assert resolved.toolset_ids == [first.id, empty.id]
      refute Map.has_key?(resolved, :tool_selection_error)
      assert {:ok, ^raw} = Store.get(:agent, saved.id)
    end

    test "one legacy or malformed toolset denies all selected names without changing saved links" do
      {:ok, native} =
        Toolsets.create(%{
          name: "version-mixed-native",
          tool_names: ["send_message"],
          tool_contract_version: 1
        })

      on_exit(fn -> Toolsets.delete(native) end)

      for {version, suffix} <- [
            {0, "legacy"},
            {nil, "missing"},
            {"1", "string"},
            {2, "future"},
            {1.0, "float"}
          ],
          names <- [["send_message"], []] do
        {:ok, other} =
          Toolsets.create(%{name: "version-mixed-#{suffix}-#{length(names)}", tool_names: names})

        on_exit(fn -> Toolsets.delete(other) end)
        assert {:ok, raw} = Store.get(:toolset, other.id)

        raw =
          if is_nil(version),
            do: Map.delete(raw, "tool_contract_version"),
            else: Map.put(raw, "tool_contract_version", version)

        assert {:ok, _} = Store.put(:toolset, raw)

        for ids <- [[other.id], [native.id, other.id]] do
          {:ok, saved} =
            AgentConfigs.create(%{
              name: "version-mixed-agent-#{suffix}-#{length(names)}-#{length(ids)}",
              tools: ["send_message"],
              toolset_ids: ids,
              tool_contract_version: 1
            })

          assert {:ok, agent_raw} = Store.get(:agent, saved.id)
          resolved = Resolver.resolve(saved.name)
          assert Map.has_key?(resolved, :tool_selection_error)
          refute resolved[:tool_contract_version] === 1
          assert resolved.toolset_ids == ids
          assert {:ok, ^raw} = Store.get(:toolset, other.id)
          assert {:ok, ^agent_raw} = Store.get(:agent, saved.id)
        end
      end
    end

    test "invalid direct versions do not apply saved MCP expansion" do
      {:ok, saved} =
        AgentConfigs.create(%{
          name: "version-mcp-agent",
          tools: ["send_message"],
          config: %{"mcp_selection" => %{"default" => "all", "sources" => %{}}}
        })

      resolved = Resolver.resolve(saved.name)
      assert Map.has_key?(resolved, :tool_selection_error)
      assert resolved.tools == ["send_message"]
    end
  end

  describe "list_agents/0" do
    test "returns all enabled agents from DB" do
      {:ok, _} = AgentConfigs.create(%{name: "main", enabled: true})
      {:ok, _} = AgentConfigs.create(%{name: "reviewer", enabled: true})
      {:ok, _} = AgentConfigs.create(%{name: "disabled", enabled: false})

      agents = Resolver.list_agents()
      names = Enum.map(agents, & &1.name)
      assert "main" in names
      assert "reviewer" in names
      refute "disabled" in names
    end
  end

  describe "seed_defaults/0" do
    test "creates only the main default agent" do
      AgentConfigs.seed_defaults()

      main = AgentConfigs.get_by_name("main")

      assert main != nil
      assert main.name == "main"
      assert main.is_default == true
      assert AgentConfigs.get_by_name("assistant") == nil
      assert AgentConfigs.get_by_name("build") == nil
      assert AgentConfigs.get_by_name("plan") == nil

      agents =
        AgentConfigs.list()
        |> Enum.map(& &1.name)

      assert agents == ["main"]
    end

    test "does not overwrite existing main agent" do
      {:ok, _} =
        AgentConfigs.create(%{
          name: "main",
          provider: "openai",
          model: "gpt-4"
        })

      AgentConfigs.seed_defaults()

      main = AgentConfigs.get_by_name("main")
      assert main.provider == "openai"
      assert main.model == "gpt-4"
    end

    test "preserves saved retired-name and custom agents while marking main default" do
      {:ok, _} = AgentConfigs.create(%{name: "assistant", is_default: true})
      {:ok, _} = AgentConfigs.create(%{name: "build", is_default: true})
      {:ok, _} = AgentConfigs.create(%{name: "plan", is_default: true})
      {:ok, _} = AgentConfigs.create(%{name: "main", is_default: false})
      {:ok, _} = AgentConfigs.create(%{name: "reviewer", is_default: true})
      saved = Store.list(:agent)

      AgentConfigs.seed_defaults()

      for raw <- saved do
        expected = if raw["name"] == "main", do: Map.put(raw, "is_default", true), else: raw
        assert {:ok, ^expected} = Store.get(:agent, raw["id"])
      end

      assert AgentConfigs.get_by_name("main").is_default
    end

    # ADR-006 C4: the Postgres-era "only main is default" normalization invariant
    # is not reimplemented on Config.Store; test removed with the behavior.
  end
end
