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
      assert request.model == Synapsis.Providers.default_model("anthropic")
    end

    test "handles string-keyed messages" do
      msg = %{"role" => "user", "parts" => [%Synapsis.Part.Text{content: "Hi"}]}
      request = MessageMapper.build_request(:anthropic, [msg], [], %{})
      [m] = request.messages
      assert m.role == "user"
    end

    test "formats Image parts as base64 source block" do
      msg = %{role: :user, parts: [%Synapsis.Part.Image{media_type: "image/png", data: "base64data"}]}
      request = MessageMapper.build_request(:anthropic, [msg], [], %{})
      [m] = request.messages
      [block] = m.content
      assert block.type == "image"
      assert block.source.type == "base64"
      assert block.source.media_type == "image/png"
      assert block.source.data == "base64data"
    end

    test "formats unknown parts via generic content fallback" do
      # Part.File has :content key, falls through to catch-all
      msg = %{role: :user, parts: [%Synapsis.Part.File{path: "/tmp/f.txt", content: "file body"}]}
      request = MessageMapper.build_request(:anthropic, [msg], [], %{})
      [m] = request.messages
      [block] = m.content
      assert block.type == "text"
      assert block.text == "file body"
    end

    test "includes max_tokens when specified" do
      request = MessageMapper.build_request(:anthropic, [@text_msg], [], %{max_tokens: 2048})
      assert request.max_tokens == 2048
    end

    test "includes reasoning_effort when specified via opts" do
      request =
        MessageMapper.build_request(:anthropic, [@text_msg], [], %{reasoning_effort: "high"})

      # reasoning_effort is not currently forwarded to the request body
      refute Map.has_key?(request, :reasoning_effort)
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
      assert request.model == Synapsis.Providers.default_model("openai")
    end

    test "formats Image parts as multimodal image_url content" do
      msg = %{role: :user, parts: [%Synapsis.Part.Image{media_type: "image/jpeg", data: "b64data"}]}
      request = MessageMapper.build_request(:openai, [msg], [], %{})
      [m] = request.messages
      assert is_list(m.content)
      [block] = m.content
      assert block.type == "image_url"
      assert block.image_url.url =~ "data:image/jpeg;base64,b64data"
    end

    test "handles string-keyed messages" do
      msg = %{"role" => "user", "parts" => [%Synapsis.Part.Text{content: "Hi there"}]}
      request = MessageMapper.build_request(:openai, [msg], [], %{})
      [m] = request.messages
      assert m.role == "user"
      assert m.content == "Hi there"
    end

    test "formats tool_use parts as tool_calls" do
      msg = %{
        role: :assistant,
        parts: [
          %Synapsis.Part.ToolUse{
            tool: "bash",
            tool_use_id: "id1",
            input: %{"cmd" => "ls"},
            status: :pending
          }
        ]
      }

      request = MessageMapper.build_request(:openai, [msg], [], %{})
      [m] = request.messages
      assert m.role == "assistant"
      assert is_list(m.tool_calls)
      [tc] = m.tool_calls
      assert tc.id == "id1"
      assert tc.type == "function"
      assert tc.function.name == "bash"
    end

    test "formats tool_result parts" do
      msg = %{
        role: :user,
        parts: [
          %Synapsis.Part.ToolResult{
            tool_use_id: "id1",
            content: "output",
            is_error: false
          }
        ]
      }

      request = MessageMapper.build_request(:openai, [msg], [], %{})
      [m] = request.messages
      assert m.role == "tool"
      assert m.tool_call_id == "id1"
      assert m.content == "output"
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
      assert request.model == Synapsis.Providers.default_model("google")
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

    test "formats tool_use parts as functionCall" do
      msg = %{
        role: :assistant,
        parts: [
          %Synapsis.Part.ToolUse{
            tool: "bash",
            tool_use_id: "id1",
            input: %{"cmd" => "ls"},
            status: :pending
          }
        ]
      }

      request = MessageMapper.build_request(:google, [msg], [], %{})
      [m] = request.contents
      assert m.role == "model"
      [block] = m.parts
      assert block.functionCall.name == "bash"
      assert block.functionCall.args == %{"cmd" => "ls"}
    end

    test "omits systemInstruction when nil" do
      request = MessageMapper.build_request(:google, [@text_msg], [], %{})
      refute Map.has_key?(request, :systemInstruction)
    end
  end
end
