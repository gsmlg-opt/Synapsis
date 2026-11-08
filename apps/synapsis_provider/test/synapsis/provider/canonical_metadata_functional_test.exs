defmodule Synapsis.Provider.CanonicalMetadataFunctionalTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Codec, Request, StreamEvent, ToolCall}
  alias Synapsis.Provider.{EventMapper, MessageMapper, ToolName}

  @message %{role: "user", parts: [%Synapsis.Part.Text{content: "Explain this result."}]}
  @resolved_model "gemini-2.5-pro-2026-10-29"
  @tool_name "mcp:agent-note:project:synapsis:engineering:workflow:canonical-metadata:list_notes"

  test "canonical Google thinking settings encode the exact provider fields" do
    assert {:ok, request} =
             Request.new(%{
               model: "gemini-2.5-pro",
               input: [
                 %{role: :user, content: [%{type: :text, text: "Explain this result."}]}
               ],
               settings: %{
                 "thinking_config" => %{
                   "thinking_budget" => 2048,
                   "include_thoughts" => true
                 }
               }
             })

    assert request.settings == %{
             "thinking_config" => %{"thinking_budget" => 2048, "include_thoughts" => true}
           }

    assert {:ok, wire} = Codec.encode_request(:google, request)

    assert wire["generationConfig"] == %{
             "thinkingConfig" => %{"thinkingBudget" => 2048, "includeThoughts" => true}
           }
  end

  test "Google mapper preserves supplied thinking budget with atom and string option keys" do
    for opts <- [
          %{
            model: "gemini-2.5-pro",
            max_tokens: 4096,
            temperature: 0.25,
            thinking_config: %{thinking_budget: 2048, include_thoughts: true}
          },
          %{
            "model" => "gemini-2.5-pro",
            "max_tokens" => 4096,
            "temperature" => 0.25,
            "thinking_config" => %{
              "thinking_budget" => 2048,
              "include_thoughts" => true
            }
          }
        ] do
      assert {:ok, wire} = MessageMapper.build_request(:google, [@message], [], opts)

      assert wire["generationConfig"] == %{
               "maxOutputTokens" => 4096,
               "temperature" => 0.25,
               "thinkingConfig" => %{"thinkingBudget" => 2048, "includeThoughts" => true}
             }
    end
  end

  test "Google mapper preserves explicit thinking level and include thoughts false" do
    assert {:ok, wire} =
             MessageMapper.build_request(:google, [@message], [], %{
               model: "gemini-3-pro",
               thinking_config: %{thinking_level: "high", include_thoughts: false}
             })

    assert wire["generationConfig"] == %{
             "thinkingConfig" => %{"thinkingLevel" => "high", "includeThoughts" => false}
           }
  end

  test "resolved model precedes and preserves the canonical text delta" do
    event = %StreamEvent{
      type: :text_delta,
      text: "Observed answer.",
      resolved_model: @resolved_model
    }

    assert EventMapper.map_event(event) ==
             {:events,
              [
                {:resolved_model, @resolved_model},
                {:text_delta, "Observed answer."}
              ]}
  end

  test "terminal resolved model reaches the host as an ordered metadata event" do
    event = %StreamEvent{
      type: :terminal,
      stop_reason: :stop,
      resolved_model: @resolved_model
    }

    assert EventMapper.map_event(event) == {:events, [{:resolved_model, @resolved_model}]}
  end

  test "resolved model tool start restores its request local alias inside the event batch" do
    alias_name = ToolName.encode(@tool_name)
    aliases = %{alias_name => @tool_name}

    event = %StreamEvent{
      type: :tool_call_start,
      index: 2,
      call_id: "call-191",
      name: alias_name,
      resolved_model: @resolved_model
    }

    assert EventMapper.map_event(event, aliases) ==
             {:events,
              [
                {:resolved_model, @resolved_model},
                {:tool_call_delta, 2, "call-191", @tool_name, ""}
              ]}
  end

  test "resolved model tool delta preserves argument bytes and restores its nested alias" do
    alias_name = ToolName.encode(@tool_name)
    aliases = %{alias_name => @tool_name}

    event = %StreamEvent{
      type: :tool_call_delta,
      index: 2,
      call_id: "call-191",
      name: alias_name,
      arguments_delta: "{\"query\":\"workflow",
      resolved_model: @resolved_model
    }

    assert EventMapper.map_event(event, aliases) ==
             {:events,
              [
                {:resolved_model, @resolved_model},
                {:tool_call_delta, 2, "call-191", @tool_name, "{\"query\":\"workflow"}
              ]}
  end

  test "resolved model tool completion preserves structured arguments and restores its nested alias" do
    alias_name = ToolName.encode(@tool_name)
    aliases = %{alias_name => @tool_name}

    event = %StreamEvent{
      type: :tool_call_done,
      index: 2,
      call_id: "call-191",
      name: alias_name,
      content: %ToolCall{
        id: "call-191",
        name: alias_name,
        raw_arguments: {:structured, %{"query" => "workflow", "limit" => 5}}
      },
      resolved_model: @resolved_model
    }

    assert EventMapper.map_event(event, aliases) ==
             {:events,
              [
                {:resolved_model, @resolved_model},
                {:tool_call_done, 2, "call-191", @tool_name,
                 %{"query" => "workflow", "limit" => 5}}
              ]}
  end
end
