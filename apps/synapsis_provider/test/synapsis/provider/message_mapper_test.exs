defmodule Synapsis.Provider.MessageMapperTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.MessageMapper

  @text_msg %{
    role: :user,
    parts: [%Synapsis.Part.Text{content: "Hello"}]
  }

  @tool_use_msg %{
    role: :assistant,
    parts: [
      %Synapsis.Part.Text{content: "Let me read that."},
      %Synapsis.Part.ToolUse{
        tool: "file_read",
        tool_use_id: "toolu_123",
        input: %{"path" => "/tmp/test.txt"},
        status: :pending
      }
    ]
  }

  @tool_result_msg %{
    role: :user,
    parts: [
      %Synapsis.Part.ToolResult{
        tool_use_id: "toolu_123",
        content: "file contents here",
        is_error: false
      }
    ]
  }

  @reasoning_msg %{
    role: :assistant,
    parts: [%Synapsis.Part.Reasoning{content: "Let me think..."}]
  }

  @sample_tools [
    %{name: "file_read", description: "Read a file", parameters: %{"type" => "object"}}
  ]

  # ---------------------------------------------------------------------------
  # Anthropic
  # ---------------------------------------------------------------------------

  describe "build_request/4 :anthropic" do
    test "formats basic text message" do
      request = MessageMapper.build_request(:anthropic, [@text_msg], [], %{model: "claude-sonnet-4-20250514"})

      assert request.model == "claude-sonnet-4-20250514"
      assert request.stream == true
      assert length(request.messages) == 1

      [msg] = request.messages
      assert msg.role == "user"
      assert [%{type: "text", text: "Hello"}] = msg.content
    end

    test "includes system prompt" do
      request =
        MessageMapper.build_request(:anthropic, [@text_msg], [], %{
          model: "claude-sonnet-4-20250514",
          system_prompt: "You are helpful"
        })

      assert request.system == "You are helpful"
    end

    test "omits system when nil" do
      request = MessageMapper.build_request(:anthropic, [@text_msg], [], %{})
      refute Map.has_key?(request, :system)
    end

    test "formats tool_use parts" do
      request = MessageMapper.build_request(:anthropic, [@tool_use_msg], [], %{})

      [msg] = request.messages
      assert msg.role == "assistant"
      assert length(msg.content) == 2

      tool_block = Enum.at(msg.content, 1)
      assert tool_block.type == "tool_use"
      assert tool_block.name == "file_read"
      assert tool_block.id == "toolu_123"
    end

    test "formats tool_result parts" do
      request = MessageMapper.build_request(:anthropic, [@tool_result_msg], [], %{})

      [msg] = request.messages
      [block] = msg.content
      assert block.type == "tool_result"
      assert block.tool_use_id == "toolu_123"
      assert block.is_error == false
    end

    test "formats reasoning parts" do
      request = MessageMapper.build_request(:anthropic, [@reasoning_msg], [], %{})
      [msg] = request.messages
      [block] = msg.content
      assert block.type == "text"
      assert String.contains?(block.text, "thinking")
    end

    test "formats tools" do
      request = MessageMapper.build_request(:anthropic, [], @sample_tools, %{})
      assert length(request.tools) == 1
      [tool] = request.tools
      assert tool.name == "file_read"
      assert tool.input_schema == %{"type" => "object"}
    end

    test "omits tools when empty" do
      request = MessageMapper.build_request(:anthropic, [], [], %{})
      refute Map.has_key?(request, :tools)
    end

    test "uses default model" do
      request = MessageMapper.build_request(:anthropic, [], [], %{})
      assert request.model == "claude-sonnet-4-20250514"
    end

    test "handles string-keyed messages" do
      msg = %{"role" => "user", "parts" => [%Synapsis.Part.Text{content: "Hi"}]}
      request = MessageMapper.build_request(:anthropic, [msg], [], %{})
      [m] = request.messages
      assert m.role == "user"
    end
  end

  # ---------------------------------------------------------------------------
  # OpenAI
  # ---------------------------------------------------------------------------

  describe "build_request/4 :openai" do
    test "formats basic text message" do
      request = MessageMapper.build_request(:openai, [@text_msg], [], %{model: "gpt-4o"})

      assert request.model == "gpt-4o"
      assert request.stream == true
      assert length(request.messages) == 1

      [msg] = request.messages
      assert msg.role == "user"
      assert msg.content == "Hello"
    end

    test "includes system as message" do
      request =
        MessageMapper.build_request(:openai, [@text_msg], [], %{
          model: "gpt-4o",
          system_prompt: "You are helpful"
        })

      assert length(request.messages) == 2
      [sys, _user] = request.messages
      assert sys.role == "system"
      assert sys.content == "You are helpful"
    end

    test "merges multi-part text content" do
      msg = %{
        role: :user,
        parts: [
          %Synapsis.Part.Text{content: "First"},
          %Synapsis.Part.Text{content: "Second"}
        ]
      }

      request = MessageMapper.build_request(:openai, [msg], [], %{})
      [m] = request.messages
      assert m.content == "First\nSecond"
    end

    test "formats tools as function type" do
      request = MessageMapper.build_request(:openai, [], @sample_tools, %{})
      [tool] = request.tools
      assert tool.type == "function"
      assert tool.function.name == "file_read"
      assert tool.function.parameters == %{"type" => "object"}
    end

    test "uses default model" do
      request = MessageMapper.build_request(:openai, [], [], %{})
      assert request.model == "gpt-4o"
    end
  end

  # ---------------------------------------------------------------------------
  # Google
  # ---------------------------------------------------------------------------

  describe "build_request/4 :google" do
    test "formats basic text message" do
      request = MessageMapper.build_request(:google, [@text_msg], [], %{model: "gemini-2.0-flash"})

      assert request.model == "gemini-2.0-flash"
      assert request.stream == true
      assert length(request.contents) == 1

      [msg] = request.contents
      assert msg.role == "user"
      assert [%{text: "Hello"}] = msg.parts
    end

    test "maps assistant role to model" do
      msg = %{role: :assistant, parts: [%Synapsis.Part.Text{content: "Hi"}]}
      request = MessageMapper.build_request(:google, [msg], [], %{})
      [m] = request.contents
      assert m.role == "model"
    end

    test "includes systemInstruction" do
      request =
        MessageMapper.build_request(:google, [@text_msg], [], %{
          system_prompt: "You are helpful"
        })

      assert request.systemInstruction == %{parts: [%{text: "You are helpful"}]}
    end

    test "formats tools as functionDeclarations" do
      request = MessageMapper.build_request(:google, [], @sample_tools, %{})
      [tool_group] = request.tools
      [decl] = tool_group.functionDeclarations
      assert decl.name == "file_read"
    end

    test "uses default model" do
      request = MessageMapper.build_request(:google, [], [], %{})
      assert request.model == "gemini-2.0-flash"
    end

    test "formats tool_result parts via generic content handler" do
      msg = %{
        role: :user,
        parts: [
          %Synapsis.Part.ToolResult{
            tool_use_id: "toolu_x",
            content: "file contents here",
            is_error: false
          }
        ]
      }

      request = MessageMapper.build_request(:google, [msg], [], %{})
      [m] = request.contents
      [block] = m.parts
      assert block.text == "file contents here"
    end

    test "formats image parts as inlineData" do
      msg = %{
        role: :user,
        parts: [%Synapsis.Part.Image{media_type: "image/png", data: "base64data"}]
      }

      request = MessageMapper.build_request(:google, [msg], [], %{})
      [m] = request.contents
      [block] = m.parts
      assert block.inlineData.mimeType == "image/png"
      assert block.inlineData.data == "base64data"
    end

    test "handles string-keyed messages" do
      msg = %{"role" => "user", "parts" => [%Synapsis.Part.Text{content: "Hi"}]}
      request = MessageMapper.build_request(:google, [msg], [], %{})
      [m] = request.contents
      assert m.role == "user"
      assert [%{text: "Hi"}] = m.parts
    end
  end
end
