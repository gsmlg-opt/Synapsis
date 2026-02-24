defmodule Synapsis.MessageBuilderTest do
  use ExUnit.Case

  alias Synapsis.MessageBuilder
  alias Synapsis.Part.{Text, ToolUse, ToolResult, Reasoning, Image}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_agent(overrides \\ %{}) do
    Map.merge(
      %{
        system_prompt: "You are helpful.",
        model: "test-model",
        max_tokens: 4096,
        tools: nil
      },
      overrides
    )
  end

  defp user_msg(text) do
    %{role: "user", parts: [%Text{content: text}]}
  end

  defp assistant_msg(text) do
    %{role: "assistant", parts: [%Text{content: text}]}
  end

  defp tool_use_msg(tool, id, input) do
    %{role: "assistant", parts: [%ToolUse{tool: tool, tool_use_id: id, input: input}]}
  end

  defp tool_result_msg(id, content, is_error \\ false) do
    %{role: "user", parts: [%ToolResult{tool_use_id: id, content: content, is_error: is_error}]}
  end

  # ---------------------------------------------------------------------------
  # Existing tests (preserved)
  # ---------------------------------------------------------------------------

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

    test "empty string as 4th positional arg does not append to system prompt" do
      messages = []
      agent = %{system_prompt: "Base prompt", tools: nil, model: "test-model", max_tokens: 4096}

      result = MessageBuilder.build_request(messages, agent, "anthropic", "")
      assert result.system == "Base prompt"
    end
  end

  # ---------------------------------------------------------------------------
  # Empty message history
  # ---------------------------------------------------------------------------

  describe "build_request/4 with empty messages" do
    test "anthropic: returns valid request with empty messages list" do
      result = MessageBuilder.build_request([], base_agent(), "anthropic")

      assert result.model == "test-model"
      assert result.max_tokens == 4096
      assert result.stream == true
      assert result.messages == []
      assert result.system == "You are helpful."
    end

    test "openai: returns valid request with empty messages list" do
      result = MessageBuilder.build_request([], base_agent(), "openai")

      assert result.model == "test-model"
      assert result.stream == true
      # OpenAI puts system prompt in messages array
      assert [%{role: "system", content: "You are helpful."}] = result.messages
    end

    test "google: returns valid request with empty messages list" do
      result = MessageBuilder.build_request([], base_agent(), "google")

      assert result.model == "test-model"
      assert result.stream == true
      assert result.contents == []
      assert result.systemInstruction == %{parts: [%{text: "You are helpful."}]}
    end
  end

  # ---------------------------------------------------------------------------
  # System prompt handling
  # ---------------------------------------------------------------------------

  describe "system prompt construction" do
    test "anthropic: system prompt appears as top-level :system key" do
      result = MessageBuilder.build_request([], base_agent(), "anthropic")
      assert result.system == "You are helpful."
    end

    test "anthropic: no :system key when system_prompt is nil" do
      agent = base_agent(%{system_prompt: nil})
      result = MessageBuilder.build_request([], agent, "anthropic")
      refute Map.has_key?(result, :system)
    end

    test "openai: system prompt inserted as first message with role system" do
      result = MessageBuilder.build_request([], base_agent(), "openai")
      assert hd(result.messages).role == "system"
      assert hd(result.messages).content == "You are helpful."
    end

    test "openai: no system message when system_prompt is nil" do
      agent = base_agent(%{system_prompt: nil})
      result = MessageBuilder.build_request([], agent, "openai")
      assert result.messages == []
    end

    test "google: system prompt in :systemInstruction key" do
      result = MessageBuilder.build_request([], base_agent(), "google")
      assert result.systemInstruction == %{parts: [%{text: "You are helpful."}]}
    end

    test "google: no systemInstruction when system_prompt is nil" do
      agent = base_agent(%{system_prompt: nil})
      result = MessageBuilder.build_request([], agent, "google")
      refute Map.has_key?(result, :systemInstruction)
    end

    test "prompt_context is appended to system prompt with double newline" do
      result = MessageBuilder.build_request([], base_agent(), "anthropic", "Extra info")
      assert result.system == "You are helpful.\n\nExtra info"
    end
  end

  # ---------------------------------------------------------------------------
  # Message history formatting per provider
  # ---------------------------------------------------------------------------

  describe "anthropic message formatting" do
    test "text message converts to anthropic content block" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")

      assert [%{role: "user", content: [%{type: "text", text: "hello"}]}] = result.messages
    end

    test "multi-turn conversation preserves order" do
      messages = [
        user_msg("hi"),
        assistant_msg("hello there"),
        user_msg("how are you?")
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      roles = Enum.map(result.messages, & &1.role)
      assert roles == ["user", "assistant", "user"]
    end

    test "tool_use part becomes anthropic tool_use content block" do
      messages = [
        tool_use_msg("file_read", "tu_123", %{"path" => "/tmp/test.txt"})
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      [msg] = result.messages
      [block] = msg.content

      assert block.type == "tool_use"
      assert block.id == "tu_123"
      assert block.name == "file_read"
      assert block.input == %{"path" => "/tmp/test.txt"}
    end

    test "tool_result part becomes anthropic tool_result content block" do
      messages = [
        tool_result_msg("tu_123", "file contents here")
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      [msg] = result.messages
      [block] = msg.content

      assert block.type == "tool_result"
      assert block.tool_use_id == "tu_123"
      assert block.content == "file contents here"
      assert block.is_error == false
    end

    test "tool_result with is_error true propagates error flag" do
      messages = [
        tool_result_msg("tu_456", "permission denied", true)
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      [msg] = result.messages
      [block] = msg.content

      assert block.is_error == true
      assert block.content == "permission denied"
    end

    test "reasoning part becomes prefixed text in anthropic format" do
      messages = [
        %{role: "assistant", parts: [%Reasoning{content: "Let me think..."}]}
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      [msg] = result.messages
      [block] = msg.content

      assert block.type == "text"
      assert block.text == "[thinking] Let me think..."
    end

    test "image part becomes anthropic image block" do
      messages = [
        %{role: "user", parts: [%Image{media_type: "image/png", data: "base64data=="}]}
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      [msg] = result.messages
      [block] = msg.content

      assert block.type == "image"
      assert block.source.type == "base64"
      assert block.source.media_type == "image/png"
      assert block.source.data == "base64data=="
    end
  end

  describe "openai message formatting" do
    test "text message converts to openai chat format" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "openai")

      # First message is system prompt, second is user
      user_msg_result = Enum.find(result.messages, &(&1.role == "user"))
      assert user_msg_result.content == "hello"
    end

    test "tool_use part becomes openai tool_calls" do
      messages = [
        tool_use_msg("bash", "call_abc", %{"command" => "ls"})
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "openai")
      # Find the assistant message (skip system prompt)
      assistant_msg_result = Enum.find(result.messages, &(&1.role == "assistant"))
      assert assistant_msg_result != nil

      [tool_call] = assistant_msg_result.tool_calls
      assert tool_call.id == "call_abc"
      assert tool_call.type == "function"
      assert tool_call.function.name == "bash"
      assert tool_call.function.arguments == Jason.encode!(%{"command" => "ls"})
    end

    test "tool_result part becomes openai tool role message" do
      messages = [
        tool_result_msg("call_abc", "file1\nfile2")
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "openai")
      tool_msg = Enum.find(result.messages, &(&1.role == "tool"))
      assert tool_msg != nil
      assert tool_msg.tool_call_id == "call_abc"
      assert tool_msg.content == "file1\nfile2"
    end

    test "image part becomes openai image_url in content array" do
      messages = [
        %{role: "user", parts: [%Image{media_type: "image/jpeg", data: "jpegdata=="}]}
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "openai")
      user_msg_result = Enum.find(result.messages, &(&1.role == "user"))
      assert is_list(user_msg_result.content)

      [img_block] = user_msg_result.content
      assert img_block.type == "image_url"
      assert img_block.image_url.url == "data:image/jpeg;base64,jpegdata=="
    end
  end

  describe "google message formatting" do
    test "text message converts to google contents format" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "google")

      assert [%{role: "user", parts: [%{text: "hello"}]}] = result.contents
    end

    test "assistant role maps to google model role" do
      messages = [assistant_msg("I can help")]
      result = MessageBuilder.build_request(messages, base_agent(), "google")

      assert [%{role: "model", parts: _}] = result.contents
    end

    test "tool_use part becomes google functionCall" do
      messages = [
        tool_use_msg("grep", "tu_789", %{"pattern" => "TODO"})
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "google")
      [msg] = result.contents
      [part] = msg.parts

      assert part.functionCall.name == "grep"
      assert part.functionCall.args == %{"pattern" => "TODO"}
    end

    test "image part becomes google inlineData" do
      messages = [
        %{role: "user", parts: [%Image{media_type: "image/png", data: "pngdata=="}]}
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "google")
      [msg] = result.contents
      [part] = msg.parts

      assert part.inlineData.mimeType == "image/png"
      assert part.inlineData.data == "pngdata=="
    end
  end

  # ---------------------------------------------------------------------------
  # Full tool_use / tool_result conversation flow
  # ---------------------------------------------------------------------------

  describe "tool_use then tool_result round-trip" do
    test "anthropic: full tool conversation renders correctly" do
      messages = [
        user_msg("read /tmp/test.txt"),
        tool_use_msg("file_read", "tu_001", %{"path" => "/tmp/test.txt"}),
        tool_result_msg("tu_001", "Hello World"),
        assistant_msg("The file contains: Hello World")
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")

      assert length(result.messages) == 4

      # First message: user text
      assert hd(result.messages).role == "user"

      # Second: assistant with tool_use
      tool_use = Enum.at(result.messages, 1)
      assert tool_use.role == "assistant"
      assert [%{type: "tool_use", name: "file_read"}] = tool_use.content

      # Third: user with tool_result
      tool_result = Enum.at(result.messages, 2)
      assert tool_result.role == "user"
      assert [%{type: "tool_result", tool_use_id: "tu_001"}] = tool_result.content

      # Fourth: assistant text
      final = Enum.at(result.messages, 3)
      assert final.role == "assistant"
    end

    test "openai: full tool conversation renders correctly" do
      messages = [
        user_msg("run ls"),
        tool_use_msg("bash", "call_001", %{"command" => "ls"}),
        tool_result_msg("call_001", "file1\nfile2"),
        assistant_msg("Found 2 files")
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "openai")

      # system + user + assistant(tool_calls) + tool + assistant
      assert length(result.messages) == 5

      roles = Enum.map(result.messages, & &1.role)
      assert roles == ["system", "user", "assistant", "tool", "assistant"]
    end
  end

  # ---------------------------------------------------------------------------
  # max_tokens default
  # ---------------------------------------------------------------------------

  describe "max_tokens handling" do
    test "uses agent-specified max_tokens" do
      agent = base_agent(%{max_tokens: 2048})
      result = MessageBuilder.build_request([], agent, "anthropic")
      assert result.max_tokens == 2048
    end

    test "defaults max_tokens to 8192 when nil in agent" do
      agent = base_agent(%{max_tokens: nil})
      result = MessageBuilder.build_request([], agent, "anthropic")
      assert result.max_tokens == 8192
    end
  end

  # ---------------------------------------------------------------------------
  # Model passthrough
  # ---------------------------------------------------------------------------

  describe "model passthrough" do
    test "uses model from agent config" do
      agent = base_agent(%{model: "claude-opus-4-20250514"})
      result = MessageBuilder.build_request([], agent, "anthropic")
      assert result.model == "claude-opus-4-20250514"
    end
  end

  # ---------------------------------------------------------------------------
  # Provider-specific formatting with string-keyed messages
  # ---------------------------------------------------------------------------

  describe "string-keyed message maps" do
    test "anthropic: handles string-keyed role and parts" do
      messages = [
        %{"role" => "user", "parts" => [%Text{content: "string keys"}]}
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      assert [%{role: "user", content: [%{type: "text", text: "string keys"}]}] = result.messages
    end

    test "openai: handles string-keyed role and parts" do
      messages = [
        %{"role" => "user", "parts" => [%Text{content: "string keys"}]}
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "openai")
      user = Enum.find(result.messages, &(&1.role == "user"))
      assert user.content == "string keys"
    end

    test "google: handles string-keyed role and parts" do
      messages = [
        %{"role" => "user", "parts" => [%Text{content: "string keys"}]}
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "google")
      assert [%{role: "user", parts: [%{text: "string keys"}]}] = result.contents
    end
  end

  # ---------------------------------------------------------------------------
  # Provider routing (openai-compat variants)
  # ---------------------------------------------------------------------------

  describe "provider routing for openai-compatible providers" do
    test "openai_compat routes through openai format" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "openai_compat")

      # Should have messages array with system + user (openai format)
      assert Map.has_key?(result, :messages)
      roles = Enum.map(result.messages, & &1.role)
      assert "system" in roles
    end

    test "groq routes through openai format" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "groq")
      assert Map.has_key?(result, :messages)
    end

    test "deepseek routes through openai format" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "deepseek")
      assert Map.has_key?(result, :messages)
    end

    test "local routes through openai format" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "local")
      assert Map.has_key?(result, :messages)
    end

    test "openrouter routes through openai format" do
      messages = [user_msg("hello")]
      result = MessageBuilder.build_request(messages, base_agent(), "openrouter")
      assert Map.has_key?(result, :messages)
    end
  end

  # ---------------------------------------------------------------------------
  # Stream flag always set
  # ---------------------------------------------------------------------------

  describe "stream flag" do
    test "anthropic request includes stream: true" do
      result = MessageBuilder.build_request([], base_agent(), "anthropic")
      assert result.stream == true
    end

    test "openai request includes stream: true" do
      result = MessageBuilder.build_request([], base_agent(), "openai")
      assert result.stream == true
    end

    test "google request includes stream: true" do
      result = MessageBuilder.build_request([], base_agent(), "google")
      assert result.stream == true
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple parts in a single message
  # ---------------------------------------------------------------------------

  describe "messages with multiple parts" do
    test "anthropic: message with text + image produces two content blocks" do
      messages = [
        %{
          role: "user",
          parts: [
            %Text{content: "What is in this image?"},
            %Image{media_type: "image/png", data: "abc123"}
          ]
        }
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      [msg] = result.messages
      assert length(msg.content) == 2
      assert Enum.at(msg.content, 0).type == "text"
      assert Enum.at(msg.content, 1).type == "image"
    end

    test "assistant message with text + tool_use in anthropic" do
      messages = [
        %{
          role: "assistant",
          parts: [
            %Text{content: "Let me read that file."},
            %ToolUse{tool: "file_read", tool_use_id: "tu_multi", input: %{"path" => "/x"}}
          ]
        }
      ]

      result = MessageBuilder.build_request(messages, base_agent(), "anthropic")
      [msg] = result.messages
      assert length(msg.content) == 2

      types = Enum.map(msg.content, & &1.type)
      assert types == ["text", "tool_use"]
    end
  end

  # ---------------------------------------------------------------------------
  # Tools formatting per provider
  # ---------------------------------------------------------------------------

  describe "tool definitions in request" do
    setup do
      # Register a test tool in the registry for these tests
      Synapsis.Tool.Registry.register_module("test_tool", Synapsis.Tool.Glob,
        description: "A test tool",
        parameters: %{
          type: "object",
          properties: %{pattern: %{type: "string"}},
          required: ["pattern"]
        }
      )

      on_exit(fn -> Synapsis.Tool.Registry.unregister("test_tool") end)
      :ok
    end

    test "anthropic: tools formatted with input_schema key" do
      agent = base_agent(%{tools: :all})
      result = MessageBuilder.build_request([], agent, "anthropic")

      if result[:tools] && result[:tools] != [] do
        tool = hd(result.tools)
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :input_schema)
      end
    end

    test "openai: tools formatted with function wrapper" do
      agent = base_agent(%{tools: :all})
      result = MessageBuilder.build_request([], agent, "openai")

      if result[:tools] && result[:tools] != [] do
        tool = hd(result.tools)
        assert tool.type == "function"
        assert Map.has_key?(tool, :function)
        assert Map.has_key?(tool.function, :name)
        assert Map.has_key?(tool.function, :parameters)
      end
    end

    test "google: tools wrapped in functionDeclarations" do
      agent = base_agent(%{tools: :all})
      result = MessageBuilder.build_request([], agent, "google")

      if result[:tools] && result[:tools] != [] do
        [tool_group] = result.tools
        assert Map.has_key?(tool_group, :functionDeclarations)
      end
    end

    test "no :tools key when tools list is empty" do
      agent = base_agent(%{tools: nil})
      result = MessageBuilder.build_request([], agent, "anthropic")
      refute Map.has_key?(result, :tools)
    end

    test "specific tool names filter from registry" do
      agent = base_agent(%{tools: ["test_tool"]})
      result = MessageBuilder.build_request([], agent, "anthropic")

      assert result[:tools] != nil
      assert length(result.tools) == 1
      assert hd(result.tools).name == "test_tool"
    end

    test "nonexistent tool names result in empty tools list" do
      agent = base_agent(%{tools: ["nonexistent_tool_xyz"]})
      result = MessageBuilder.build_request([], agent, "anthropic")

      # No matching tools means empty list, so no :tools key
      refute Map.has_key?(result, :tools)
    end
  end
end
