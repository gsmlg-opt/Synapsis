defmodule Synapsis.Agent.ResolverTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Resolver

  describe "resolve/2" do
    test "returns default build agent" do
      agent = Resolver.resolve("build")
      assert agent.name == "build"
      assert agent.read_only == false
      assert "bash" in agent.tools
      assert "file_read" in agent.tools
    end

    test "returns default plan agent" do
      agent = Resolver.resolve("plan")
      assert agent.name == "plan"
      assert agent.read_only == true
      refute "bash" in agent.tools
      assert "file_read" in agent.tools
    end

    test "merges project overrides" do
      config = %{
        "agents" => %{
          "build" => %{
            "model" => "custom-model",
            "systemPrompt" => "Custom prompt"
          }
        }
      }

      agent = Resolver.resolve("build", config)
      assert agent.model == "custom-model"
      assert agent.system_prompt == "Custom prompt"
    end

    test "overrides tools when provided" do
      config = %{
        "agents" => %{
          "build" => %{
            "tools" => ["file_read", "grep"]
          }
        }
      }

      agent = Resolver.resolve("build", config)
      assert agent.tools == ["file_read", "grep"]
    end

    test "defaults provider to nil" do
      agent = Resolver.resolve("build")
      assert agent.provider == nil
    end

    test "allows per-agent provider override" do
      config = %{
        "agents" => %{
          "build" => %{
            "provider" => "openai"
          }
        }
      }

      agent = Resolver.resolve("build", config)
      assert agent.provider == "openai"
    end

    test "unknown agent name defaults to build agent config" do
      agent = Resolver.resolve("unknown_agent_xyz")
      assert agent.name == "unknown_agent_xyz"
      assert agent.read_only == false
      assert "bash" in agent.tools
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
      # Non-list override is ignored, default tools returned
      assert "bash" in agent.tools
    end
  end
end
