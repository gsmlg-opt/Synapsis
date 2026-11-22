defmodule Synapsis.Provider.MessageMapperTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.{MessageMapper, ToolName}

  @text_message %{role: "user", parts: [%Synapsis.Part.Text{content: "Hello"}]}
  @tool %{
    name: "mcp:backplane:web::search",
    description: "Search",
    parameters: %{"type" => "object"}
  }

  test "encodes Anthropic text, system, image, tools, and limits with string keys" do
    messages = [
      @text_message,
      %{
        role: "user",
        parts: [%Synapsis.Part.Image{media_type: "image/png", data: Base.encode64(<<0, 1, 2>>)}]
      }
    ]

    assert {:ok, wire} =
             MessageMapper.build_request(:anthropic, messages, [@tool], %{
               model: "claude-test",
               system_prompt: "Be precise",
               max_tokens: 2048
             })

    assert wire["model"] == "claude-test"
    assert wire["max_tokens"] == 2048
    assert wire["system"] == [%{"type" => "text", "text" => "Be precise"}]
    assert [%{"name" => tool_name}] = wire["tools"]
    assert ToolName.decode(tool_name) == "mcp:backplane:web::search"
    assert get_in(wire, ["messages", Access.at(1), "content", Access.at(0), "type"]) == "image"
    assert Enum.all?(Map.keys(wire), &is_binary/1)
  end

  test "accepts a 20 MiB CLI image without applying upload count limits to history" do
    history =
      for index <- 1..5 do
        %{
          role: "user",
          parts: [%Synapsis.Part.Image{media_type: "image/png", data: Base.encode64(<<index>>)}]
        }
      end

    image = %Synapsis.Part.Image{
      media_type: "image/png",
      data: Base.encode64(:binary.copy(<<0>>, 20 * 1024 * 1024))
    }

    assert {:ok, wire} =
             MessageMapper.build_request(
               :anthropic,
               history ++ [%{role: "user", parts: [image]}],
               [],
               %{model: "claude-test"}
             )

    assert length(wire["messages"]) == 6

    assert byte_size(
             get_in(wire, ["messages", Access.at(5), "content", Access.at(0), "source", "data"])
           ) ==
             27_962_028
  end

  test "encodes a Responses user image between its surrounding text" do
    data =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVQI12P4z8AAAAACAAHiIbwzAAAAAElFTkSuQmCC"

    messages = [
      %{
        role: "user",
        parts: [
          %Synapsis.Part.Text{content: "before"},
          %Synapsis.Part.Image{media_type: "image/png", data: data},
          %Synapsis.Part.Text{content: "after"}
        ]
      }
    ]

    url = "data:image/png;base64," <> data

    assert {:ok, %{"input" => [message]}} =
             MessageMapper.build_request(:openai_responses, messages, [], %{model: "fixture"})

    assert %{
             "role" => "user",
             "content" => [
               %{"type" => "input_text", "text" => "before"},
               %{"type" => "input_image", "image_url" => ^url},
               %{"type" => "input_text", "text" => "after"}
             ]
           } = message
  end

  test "encodes OpenAI tool names and parallel tool results" do
    messages = [
      %{
        role: "assistant",
        parts: [
          %Synapsis.Part.ToolUse{
            tool: @tool.name,
            tool_use_id: "call-1",
            input: %{"query" => "elixir"}
          },
          %Synapsis.Part.ToolUse{
            tool: @tool.name,
            tool_use_id: "call-2",
            input: %{"query" => "otp"}
          }
        ]
      },
      %{
        role: "user",
        parts: [
          %Synapsis.Part.ToolResult{tool_use_id: "call-1", content: "one"},
          %Synapsis.Part.ToolResult{tool_use_id: "call-2", content: "two", is_error: true}
        ]
      }
    ]

    assert {:ok, wire} =
             MessageMapper.build_request(:openai_responses, messages, [@tool], %{
               model: "gpt-test"
             })

    encoded = ToolName.encode(@tool.name)
    assert get_in(wire, ["tools", Access.at(0), "name"]) == encoded

    assert [
             %{"type" => "function_call", "name" => ^encoded, "call_id" => "call-1"},
             %{"type" => "function_call", "name" => ^encoded, "call_id" => "call-2"},
             %{"type" => "function_call_output", "call_id" => "call-1", "output" => "one"},
             %{"type" => "function_call_output", "call_id" => "call-2", "output" => "two"}
           ] = wire["input"]
  end

  test "projects legacy MiniMax transcripts onto Responses without replaying old reasoning state" do
    first = %{"type" => "reasoning.text", "text" => "first", "signature" => "opaque"}
    second = %{"type" => "reasoning.text", "text" => "second"}
    third = %{"type" => "reasoning.text", "text" => "third"}

    for payloads <- [[first, second, third], [[first, second], [third]]] do
      states =
        Enum.map(payloads, fn payload ->
          %{
            source_profile: "backplane",
            source_protocol: "openai",
            kind: "minimax_reasoning_details",
            affinity: %{
              profile: "backplane",
              protocol: "openai",
              endpoint: "http://localhost:4220/v1",
              model: "minimax/MiniMax-M3"
            },
            payload: payload
          }
        end)

      messages = [
        @text_message,
        %{
          role: "assistant",
          parts: [
            %Synapsis.Part.Text{content: "Hello"},
            %Synapsis.Part.Reasoning{content: "why", provider_states: states}
          ]
        },
        @text_message
      ]

      opts = %{
        model: "minimax/MiniMax-M3",
        provider_name: "backplane",
        base_url: "http://localhost:4220/v1"
      }

      assert {:ok, wire} = MessageMapper.build_request(:openai_responses, messages, [], opts)

      assert %{
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "Hello"}]
             } = Enum.at(wire["input"], 1)

      refute inspect(wire) =~ "opaque"
      refute inspect(wire) =~ "reasoning"
    end
  end

  test "preserves explicit false stream for atom and string keys" do
    for opts <- [
          %{model: "m", provider_name: "minimax", stream: false},
          %{
            "model" => "m",
            "provider_name" => "minimax",
            "stream" => false
          }
        ] do
      assert {:ok, %{"stream" => false}} =
               MessageMapper.build_request(:openai_responses, [@text_message], [], opts)
    end
  end

  test "encodes Google generation settings for atom and string keys" do
    for opts <- [
          %{model: "gemini-test", max_tokens: 2048, temperature: 0.25},
          %{"model" => "gemini-test", "max_tokens" => 2048, "temperature" => 0.25}
        ] do
      assert {:ok, wire} = MessageMapper.build_request(:google, [@text_message], [], opts)

      assert wire["generationConfig"] == %{"maxOutputTokens" => 2048, "temperature" => 0.25}
    end
  end

  test "encodes Google tools and tool call/result pairs" do
    messages = [
      %{
        role: "assistant",
        parts: [
          %Synapsis.Part.ToolUse{
            tool: "search",
            tool_use_id: "call-1",
            input: %{"q" => "x"}
          }
        ]
      },
      %{
        role: "user",
        parts: [%Synapsis.Part.ToolResult{tool_use_id: "call-1", content: "ok"}]
      }
    ]

    tool = %{@tool | name: "search"}

    assert {:ok, wire} =
             MessageMapper.build_request(:google, messages, [tool], %{model: "gemini-test"})

    assert wire["model"] == "gemini-test"

    assert get_in(wire, ["contents", Access.at(0), "parts", Access.at(0), "functionCall", "name"]) ==
             "search"

    assert get_in(wire, [
             "contents",
             Access.at(1),
             "parts",
             Access.at(0),
             "functionResponse",
             "name"
           ]) == "search"
  end

  test "omits plain reasoning from Responses and rejects legacy signatures without origin" do
    assert {:ok, wire} =
             MessageMapper.build_request(
               :openai_responses,
               [%{role: "assistant", parts: [%Synapsis.Part.Reasoning{content: "why"}]}],
               [],
               %{model: "gpt-test"}
             )

    assert wire["input"] == []

    assert {:error, %Backplane.AiProtocol.Error{kind: :incompatible}} =
             MessageMapper.build_request(
               :anthropic,
               [
                 %{
                   role: "assistant",
                   parts: [%Synapsis.Part.Reasoning{content: "why", signature: "legacy"}]
                 }
               ],
               [],
               %{model: "claude-test"}
             )
  end

  test "replays multiple provider states in order only at matching affinity" do
    states = [provider_state("first"), provider_state("second")]

    message = %{
      role: "assistant",
      parts: [%Synapsis.Part.Reasoning{content: "", provider_states: states}]
    }

    opts = %{
      model: "claude-test",
      provider_name: "primary",
      endpoint: "https://api.example"
    }

    assert {:ok, wire} = MessageMapper.build_request(:anthropic, [message], [], opts)
    assert Enum.map(hd(wire["messages"])["content"], & &1["thinking"]) == ["first", "second"]

    assert {:error, %Backplane.AiProtocol.Error{kind: :incompatible}} =
             MessageMapper.build_request(:anthropic, [message], [], %{opts | model: "changed"})
  end

  test "replays signed state without duplicating visible reasoning" do
    message = %{
      role: "assistant",
      parts: [
        %Synapsis.Part.Reasoning{
          content: "private",
          provider_states: [provider_state("private")]
        }
      ]
    }

    assert {:ok, wire} =
             MessageMapper.build_request(:anthropic, [message], [], %{
               model: "claude-test",
               provider_name: "primary",
               endpoint: "https://api.example"
             })

    assert [%{"type" => "thinking", "thinking" => "private"}] =
             hd(wire["messages"])["content"]
  end

  test "uses the protocol default endpoint for matching signed replay" do
    state =
      provider_state("private")
      |> put_in(["affinity", "endpoint"], "https://api.anthropic.com")

    message = %{
      role: "assistant",
      parts: [%Synapsis.Part.Reasoning{content: "private", provider_states: [state]}]
    }

    assert {:ok, _wire} =
             MessageMapper.build_request(:anthropic, [message], [], %{
               model: "claude-test",
               provider_name: "primary"
             })
  end

  test "uses the same reversible tool names for definitions and history" do
    originals = ["mcp.tool", "mcp:server:web::search"]

    tools =
      Enum.map(originals, &%{name: &1, description: &1, parameters: %{"type" => "object"}})

    calls =
      originals
      |> Enum.with_index(1)
      |> Enum.map(fn {name, index} ->
        %Synapsis.Part.ToolUse{tool: name, tool_use_id: "call-#{index}", input: %{"i" => index}}
      end)

    results =
      originals
      |> Enum.with_index(1)
      |> Enum.map(fn {_name, index} ->
        %Synapsis.Part.ToolResult{tool_use_id: "call-#{index}", content: "result-#{index}"}
      end)

    messages = [%{role: "assistant", parts: calls}, %{role: "user", parts: results}]

    for protocol <- [:anthropic, :google] do
      assert {:ok, wire} =
               MessageMapper.build_request(protocol, messages, tools, %{model: "test"})

      {declarations, call_names} = tool_names(protocol, wire)
      assert declarations == call_names
      assert Enum.map(declarations, &ToolName.decode/1) == originals
      assert tool_result_count(protocol, wire) == 2
    end
  end

  test "rejects unsupported file parts rather than flattening semantics" do
    message = %{role: "user", parts: [%Synapsis.Part.File{path: "a.txt", content: "data"}]}

    assert {:error, %Backplane.AiProtocol.Error{kind: :incompatible}} =
             MessageMapper.build_request(:openai_responses, [message], [], %{model: "gpt-test"})
  end

  defp provider_state(thinking) do
    %{
      "source_profile" => "primary",
      "source_protocol" => "anthropic",
      "kind" => "anthropic_signed_thinking",
      "affinity" => %{
        "profile" => "primary",
        "protocol" => "anthropic",
        "endpoint" => "https://api.example",
        "model" => "claude-test"
      },
      "payload" => %{"thinking" => thinking, "signature" => "signature-#{thinking}"}
    }
  end

  defp tool_names(:anthropic, wire) do
    declarations = Enum.map(wire["tools"], & &1["name"])
    calls = wire["messages"] |> hd() |> Map.fetch!("content") |> Enum.map(& &1["name"])
    {declarations, calls}
  end

  defp tool_names(:google, wire) do
    declarations =
      wire["tools"] |> hd() |> Map.fetch!("functionDeclarations") |> Enum.map(& &1["name"])

    calls =
      wire["contents"] |> hd() |> Map.fetch!("parts") |> Enum.map(& &1["functionCall"]["name"])

    {declarations, calls}
  end

  defp tool_result_count(:anthropic, wire) do
    wire["messages"]
    |> Enum.flat_map(& &1["content"])
    |> Enum.count(&(&1["type"] == "tool_result"))
  end

  defp tool_result_count(:google, wire) do
    wire["contents"]
    |> Enum.flat_map(& &1["parts"])
    |> Enum.count(&Map.has_key?(&1, "functionResponse"))
  end

  describe "provider-safe tool names" do
    test "aliases long tool declarations consistently for every provider" do
      name = "mcp:agent-note:" <> String.duplicate("nested-namespace:", 8) <> "list_notes"
      tool = %{name: name, description: "List notes", parameters: %{"type" => "object"}}

      assert {:ok, anthropic} = MessageMapper.build_request(:anthropic, [], [tool], %{})
      assert {:ok, openai} = MessageMapper.build_request(:openai_responses, [], [tool], %{})
      assert {:ok, google} = MessageMapper.build_request(:google, [], [tool], %{})

      anthropic_alias = get_in(anthropic, ["tools", Access.at(0), "name"])
      openai_alias = get_in(openai, ["tools", Access.at(0), "name"])

      google_alias =
        get_in(google, ["tools", Access.at(0), "functionDeclarations", Access.at(0), "name"])

      assert anthropic_alias == openai_alias
      assert openai_alias == google_alias
      assert byte_size(openai_alias) <= 64

      for request <- [anthropic, openai, google] do
        {_wire_request, aliases} = ToolName.pop_aliases(request)
        assert ToolName.decode(openai_alias, aliases) == name
      end
    end
  end
end
