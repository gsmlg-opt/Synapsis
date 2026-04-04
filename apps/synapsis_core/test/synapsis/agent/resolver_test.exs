defmodule Synapsis.Agent.ResolverTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Resolver
  alias Synapsis.{AgentConfig, AgentConfigs, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Clean up any existing agent_configs for isolation
    Repo.delete_all(AgentConfig)
    :ok
  end

  describe "resolve/1 with no DB records (hardcoded fallback)" do
    test "returns default build agent config" do
      agent = Resolver.resolve("build")
      assert agent.name == "build"
      assert agent.read_only == false
      assert agent.reasoning_effort == "medium"
      assert agent.max_tokens == 8192
      assert agent.model == nil
      assert agent.provider == nil
      assert is_binary(agent.system_prompt)
      assert String.length(agent.system_prompt) > 0
    end

    test "returns default plan agent config" do
      agent = Resolver.resolve("plan")
      assert agent.name == "plan"
      assert agent.read_only == true
      assert agent.reasoning_effort == "high"
      assert agent.max_tokens == 8192
      refute "bash" in agent.tools
      assert "file_read" in agent.tools
    end

    test "returns proper structure with all expected keys" do
      agent = Resolver.resolve("build")

      assert Map.has_key?(agent, :name)
      assert Map.has_key?(agent, :model)
      assert Map.has_key?(agent, :provider)
      assert Map.has_key?(agent, :system_prompt)
      assert Map.has_key?(agent, :tools)
      assert Map.has_key?(agent, :reasoning_effort)
      assert Map.has_key?(agent, :read_only)
      assert Map.has_key?(agent, :max_tokens)
      assert Map.has_key?(agent, :model_tier)
    end

    test "default build agent includes all expected tools" do
      agent = Resolver.resolve("build")

      expected_tools = [
        "file_read",
        "file_edit",
        "file_write",
        "bash",
        "grep",
        "glob",
        "diagnostics",
        "fetch"
      ]

      assert agent.tools == expected_tools
    end

    test "default plan agent includes only read-only tools" do
      agent = Resolver.resolve("plan")
      expected_tools = ["file_read", "grep", "glob", "diagnostics"]
      assert agent.tools == expected_tools
    end

    test "unknown agent name falls back to build agent defaults" do
      agent = Resolver.resolve("unknown_agent_xyz")
      build = Resolver.resolve("build")

      assert agent.tools == build.tools
      assert agent.read_only == build.read_only
      assert agent.system_prompt == build.system_prompt
      assert agent.max_tokens == build.max_tokens
    end

    test "returns default assistant agent config" do
      agent = Resolver.resolve("assistant")
      assert agent.name == "assistant"
      assert agent.read_only == false
      assert agent.reasoning_effort == "high"
      assert agent.max_tokens == 8192
      assert agent.model_tier == :expert
      assert "task" in agent.tools
      assert "ask_user" in agent.tools
      refute "file_read" in agent.tools
      refute "file_edit" in agent.tools
      refute "bash" in agent.tools
    end

    test "assistant config includes orchestration tools but no filesystem tools" do
      agent = Resolver.resolve("assistant")
      # Should have these
      for tool <- ~w(task ask_user web_search todo_read todo_write enter_plan_mode exit_plan_mode) do
        assert tool in agent.tools, "expected #{tool} in assistant tools"
      end

      # Should NOT have these
      for tool <- ~w(file_read file_edit file_write bash grep glob) do
        refute tool in agent.tools, "did not expect #{tool} in assistant tools"
      end
    end

    test "accepts atom agent names" do
      agent = Resolver.resolve(:build)
      assert agent.name == "build"
      assert agent.read_only == false
    end

    test "build agent has :default model_tier" do
      agent = Resolver.resolve("build")
      assert agent.model_tier == :default
    end

    test "plan agent has :expert model_tier" do
      agent = Resolver.resolve("plan")
      assert agent.model_tier == :expert
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
  end

  describe "list_agents/0" do
    test "returns all enabled agents from DB" do
      {:ok, _} = AgentConfigs.create(%{name: "build", enabled: true})
      {:ok, _} = AgentConfigs.create(%{name: "plan", enabled: true})
      {:ok, _} = AgentConfigs.create(%{name: "disabled", enabled: false})

      agents = Resolver.list_agents()
      names = Enum.map(agents, & &1.name)
      assert "build" in names
      assert "plan" in names
      refute "disabled" in names
    end
  end

  describe "seed_defaults/0" do
    test "creates assistant, build, and plan agents" do
      AgentConfigs.seed_defaults()

      assistant = AgentConfigs.get_by_name("assistant")
      build = AgentConfigs.get_by_name("build")
      plan = AgentConfigs.get_by_name("plan")

      assert assistant != nil
      assert build != nil
      assert plan != nil
      assert assistant.name == "assistant"
      assert assistant.is_default == false
      assert build.name == "build"
      assert plan.name == "plan"
      assert build.is_default == true
      assert plan.read_only == true
    end

    test "does not overwrite existing agents" do
      {:ok, _} =
        AgentConfigs.create(%{
          name: "build",
          provider: "openai",
          model: "gpt-4"
        })

      AgentConfigs.seed_defaults()

      build = AgentConfigs.get_by_name("build")
      assert build.provider == "openai"
      assert build.model == "gpt-4"
    end
  end
end
