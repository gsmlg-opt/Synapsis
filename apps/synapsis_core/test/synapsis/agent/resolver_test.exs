defmodule Synapsis.Agent.ResolverTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Resolver
  alias Synapsis.{AgentConfig, AgentConfigs, AgentSkills, Repo, Skills, Toolsets}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Clean up any existing agent_configs for isolation
    Repo.delete_all(AgentConfig)
    :ok
  end

  describe "resolve/1 with no DB records (hardcoded fallback)" do
    test "returns default main agent config" do
      agent = Resolver.resolve("main")
      assert agent.name == "main"
      assert agent.read_only == false
      assert agent.reasoning_effort == "medium"
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
      assert Map.has_key?(agent, :read_only)
      assert Map.has_key?(agent, :max_tokens)
      assert Map.has_key?(agent, :model_tier)
      assert Map.has_key?(agent, :workspace_path)
      assert agent.workspace_path == "~/.synapsis/agents/main"
    end

    test "default main agent includes all expected tools" do
      agent = Resolver.resolve("main")

      # Filesystem + Search + Execution + Web + Planning + Orchestration +
      # Interaction + Session + Memory + Workflow + Repo/Worktree + Diagnostics
      for tool <- ~w(
        file_read file_edit file_write multi_edit file_delete file_move list_dir
        grep glob bash fetch web_search
        todo_read todo_write enter_plan_mode exit_plan_mode
        task skill tool_search ask_user sleep
        memory_save memory_search memory_update session_summarize
        board_read board_update devlog_read devlog_write
        repo_link repo_status repo_sync
        worktree_create worktree_list worktree_remove
        diagnostics
      ) do
        assert tool in agent.tools, "expected #{tool} in main agent tools"
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

    test "project default agent fills main provider and model" do
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

      {:ok, _skills} = AgentSkills.assign_skills(agent_config, [skill.id])

      agent = Resolver.resolve("skilled-agent")
      assert Enum.map(agent.skills, & &1.name) == ["review-style"]
      assert hd(agent.skills).system_prompt_fragment == "Always review tradeoffs."
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

    test "removes retired built-in agents and preserves custom agents" do
      {:ok, _} = AgentConfigs.create(%{name: "assistant", is_default: true})
      {:ok, _} = AgentConfigs.create(%{name: "build", is_default: true})
      {:ok, _} = AgentConfigs.create(%{name: "plan", is_default: true})
      {:ok, _} = AgentConfigs.create(%{name: "main", is_default: false})
      {:ok, _} = AgentConfigs.create(%{name: "reviewer", is_default: true})

      AgentConfigs.seed_defaults()

      assert AgentConfigs.get_by_name("assistant") == nil
      assert AgentConfigs.get_by_name("build") == nil
      assert AgentConfigs.get_by_name("plan") == nil
      assert AgentConfigs.get_by_name("reviewer") != nil
      assert AgentConfigs.get_by_name("main").is_default
    end

    test "create and update keep main as the only default agent" do
      {:ok, other_default} = AgentConfigs.create(%{name: "other-default", is_default: true})
      refute Repo.get!(AgentConfig, other_default.id).is_default

      {:ok, main} = AgentConfigs.create(%{name: "main", is_default: false})
      assert Repo.get!(AgentConfig, main.id).is_default

      {:ok, other} = AgentConfigs.create(%{name: "other"})
      {:ok, _other} = AgentConfigs.update(other, %{is_default: true})

      refute Repo.get!(AgentConfig, other.id).is_default
      assert Repo.get!(AgentConfig, main.id).is_default
    end
  end
end
