defmodule Synapsis.Agent.ResolverTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Resolver

  describe "resolve/1 with no overrides" do
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
      assert map_size(agent) == 8
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

    test "default agents include build and plan" do
      build = Resolver.resolve("build")
      plan = Resolver.resolve("plan")

      assert build.name == "build"
      assert plan.name == "plan"

      # They should differ in key attributes
      assert build.read_only == false
      assert plan.read_only == true
      assert build.reasoning_effort == "medium"
      assert plan.reasoning_effort == "high"
      assert length(build.tools) > length(plan.tools)
    end

    test "unknown agent name falls back to build agent defaults" do
      agent = Resolver.resolve("unknown_agent_xyz")
      build = Resolver.resolve("build")

      assert agent.name == "unknown_agent_xyz"
      assert agent.tools == build.tools
      assert agent.read_only == build.read_only
      assert agent.system_prompt == build.system_prompt
      assert agent.max_tokens == build.max_tokens
    end

    test "accepts atom agent names" do
      agent = Resolver.resolve(:build)
      assert agent.name == "build"
      assert agent.read_only == false
    end
  end

  describe "resolve/2 with overrides" do
    test "merges model override" do
      config = %{"agents" => %{"build" => %{"model" => "claude-opus-4-20250514"}}}
      agent = Resolver.resolve("build", config)
      assert agent.model == "claude-opus-4-20250514"
    end

    test "merges provider override" do
      config = %{"agents" => %{"build" => %{"provider" => "openai"}}}
      agent = Resolver.resolve("build", config)
      assert agent.provider == "openai"
    end

    test "preserves system_prompt from override" do
      custom_prompt = "You are a specialized Rust assistant."

      config = %{
        "agents" => %{
          "build" => %{"systemPrompt" => custom_prompt}
        }
      }

      agent = Resolver.resolve("build", config)
      assert agent.system_prompt == custom_prompt
    end

    test "overrides tools when provided as a list" do
      config = %{
        "agents" => %{
          "build" => %{"tools" => ["file_read", "grep"]}
        }
      }

      agent = Resolver.resolve("build", config)
      assert agent.tools == ["file_read", "grep"]
    end

    test "merges maxTokens override" do
      config = %{"agents" => %{"build" => %{"maxTokens" => 2048}}}
      agent = Resolver.resolve("build", config)
      assert agent.max_tokens == 2048
    end

    test "merges reasoningEffort override" do
      config = %{"agents" => %{"build" => %{"reasoningEffort" => "low"}}}
      agent = Resolver.resolve("build", config)
      assert agent.reasoning_effort == "low"
    end

    test "merges readOnly override" do
      config = %{"agents" => %{"build" => %{"readOnly" => true}}}
      agent = Resolver.resolve("build", config)
      assert agent.read_only == true
    end

    test "non-list tools override falls back to defaults" do
      config = %{"agents" => %{"build" => %{"tools" => "not_a_list"}}}
      agent = Resolver.resolve("build", config)
      assert "bash" in agent.tools
      assert length(agent.tools) == 8
    end

    test "empty override map preserves all defaults" do
      config = %{"agents" => %{"build" => %{}}}
      agent = Resolver.resolve("build", config)
      default = Resolver.resolve("build")

      assert agent.model == default.model
      assert agent.provider == default.provider
      assert agent.system_prompt == default.system_prompt
      assert agent.tools == default.tools
      assert agent.reasoning_effort == default.reasoning_effort
      assert agent.read_only == default.read_only
      assert agent.max_tokens == default.max_tokens
    end

    test "override for non-existent agent section preserves defaults" do
      config = %{"agents" => %{"other" => %{"model" => "gpt-4"}}}
      agent = Resolver.resolve("build", config)
      default = Resolver.resolve("build")
      assert agent.model == default.model
    end

    test "multiple fields can be overridden at once" do
      config = %{
        "agents" => %{
          "plan" => %{
            "model" => "gpt-4",
            "provider" => "openai",
            "reasoningEffort" => "low",
            "maxTokens" => 4096
          }
        }
      }

      agent = Resolver.resolve("plan", config)
      assert agent.model == "gpt-4"
      assert agent.provider == "openai"
      assert agent.reasoning_effort == "low"
      assert agent.max_tokens == 4096
      # Non-overridden fields keep defaults
      assert agent.read_only == true
    end
  end
end
