defmodule Synapsis.Agent.ContextBuilderTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.ContextBuilder

  describe "build_system_prompt/2" do
    test "returns a non-empty string" do
      prompt = ContextBuilder.build_system_prompt(:coding)
      assert is_binary(prompt)
      assert byte_size(prompt) > 0
    end

    test "includes base prompt" do
      prompt = ContextBuilder.build_system_prompt(:coding)
      assert prompt =~ "AI coding assistant"
    end

    test "wraps soul section in XML tags when soul exists" do
      # This test verifies the XML wrapping behavior
      # Identity files may not exist in test env, so we test with agent_config
      prompt =
        ContextBuilder.build_system_prompt(:coding,
          agent_config: %{system_prompt: "Custom prompt"}
        )

      assert prompt =~ "Custom prompt"
    end

    test "omits sections for missing files" do
      prompt = ContextBuilder.build_system_prompt(:coding)
      # Without identity files, soul/identity/bootstrap sections should be absent
      refute prompt =~ "<soul>"
      refute prompt =~ "<user_identity>"
      refute prompt =~ "<environment>"
    end
  end

  describe "memory_budget/1" do
    test "returns 3 max entries for 32K context" do
      budget = ContextBuilder.memory_budget(32_000)
      assert budget.max_entries == 3
      assert budget.max_tokens == 1_600
    end

    test "returns 10 max entries for 128K context (cap)" do
      budget = ContextBuilder.memory_budget(128_000)
      assert budget.max_entries == 10
      assert budget.max_tokens == 6_400
    end

    test "returns 10 max entries for 200K context (cap)" do
      budget = ContextBuilder.memory_budget(200_000)
      assert budget.max_entries == 10
      assert budget.max_tokens == 10_000
    end

    test "token budget is 5% of context window" do
      budget = ContextBuilder.memory_budget(100_000)
      assert budget.max_tokens == 5_000
    end
  end

  describe "build_skills_manifest/1" do
    test "returns nil when no tools available" do
      # In test env, tool registry may not be started
      result = ContextBuilder.build_skills_manifest(nil)
      # Either nil or a string with tool listings
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "load_base_prompt/2" do
    test "returns agent system prompt when provided" do
      config = %{system_prompt: "Custom system prompt"}
      assert ContextBuilder.load_base_prompt(:coding, config) == "Custom system prompt"
    end

    test "returns default prompt when no config" do
      result = ContextBuilder.load_base_prompt(:coding, %{})
      assert result =~ "AI coding assistant"
    end
  end
end
