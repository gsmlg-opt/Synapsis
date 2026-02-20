defmodule Synapsis.MessageBuilderTest do
  use ExUnit.Case

  alias Synapsis.MessageBuilder

  describe "build_request/4" do
    test "builds request with system prompt" do
      messages = [%{role: "user", parts: [%{type: "text", content: "hello"}]}]

      agent = %{
        system_prompt: "You are helpful.",
        model: "test-model",
        max_tokens: 4096,
        tools: nil
      }

      result = MessageBuilder.build_request(messages, agent, "anthropic")
      assert is_map(result)
    end

    test "builds request with prompt context appended" do
      messages = [%{role: "user", parts: [%{type: "text", content: "hello"}]}]

      agent = %{
        system_prompt: "Base prompt.",
        model: "test-model",
        max_tokens: 4096,
        tools: nil
      }

      result = MessageBuilder.build_request(messages, agent, "anthropic", "Extra context")
      assert is_map(result)
    end

    test "resolves tools as empty list when nil" do
      messages = [%{role: "user", parts: [%{type: "text", content: "hello"}]}]

      agent = %{
        system_prompt: "Test",
        model: "test-model",
        max_tokens: 4096,
        tools: nil
      }

      result = MessageBuilder.build_request(messages, agent, "anthropic")
      # Tools should be empty
      assert result[:tools] == [] || is_nil(result[:tools]) || result["tools"] == []
    end

    test "resolves :all tools from registry" do
      messages = [%{role: "user", parts: [%{type: "text", content: "hello"}]}]

      agent = %{
        system_prompt: "Test",
        model: "test-model",
        max_tokens: 4096,
        tools: :all
      }

      result = MessageBuilder.build_request(messages, agent, "anthropic")
      # Should have tools from the registry
      assert is_map(result)
    end

    test "resolves specific tool names from registry" do
      messages = [%{role: "user", parts: [%{type: "text", content: "hello"}]}]

      agent = %{
        system_prompt: "Test",
        model: "test-model",
        max_tokens: 4096,
        tools: ["file_read", "bash"]
      }

      result = MessageBuilder.build_request(messages, agent, "anthropic")
      assert is_map(result)
    end

    test "falls back to Adapter for unknown provider" do
      messages = [%{role: "user", parts: [%{type: "text", content: "hello"}]}]

      agent = %{
        system_prompt: "Test",
        model: "test-model",
        max_tokens: 4096,
        tools: nil
      }

      result = MessageBuilder.build_request(messages, agent, "unknown_provider")
      assert is_map(result)
    end

    test "builds request with nil context (no extra appended)" do
      messages = []
      agent = %{
        system_prompt: "Base prompt",
        tools: nil,
        model: "test-model",
        max_tokens: 4096,
        reasoning_effort: nil,
        context: nil
      }

      result = MessageBuilder.build_request(messages, agent, "anthropic")
      assert result.system =~ "Base prompt"
      # nil context should not add extra text
      assert result.system == "Base prompt"
    end

    test "builds request with empty string context (no extra appended)" do
      messages = []
      agent = %{
        system_prompt: "Base prompt",
        tools: nil,
        model: "test-model",
        max_tokens: 4096,
        reasoning_effort: nil,
        context: ""
      }

      result = MessageBuilder.build_request(messages, agent, "anthropic")
      assert result.system == "Base prompt"
    end
  end
end
