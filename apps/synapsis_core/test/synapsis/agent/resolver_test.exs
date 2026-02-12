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
  end
end
