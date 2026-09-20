defmodule Synapsis.Provider.EventMapperTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.{Affinity, ContentBlock, Error, ProviderState, StreamEvent, Usage}
  alias Synapsis.Provider.{EventMapper, ToolName}

  test "maps canonical text and reasoning deltas" do
    assert {:text_delta, "hello"} =
             EventMapper.map_event(%StreamEvent{type: :text_delta, text: "hello"})

    assert {:reasoning_delta, "private"} =
             EventMapper.map_event(%StreamEvent{type: :reasoning_delta, text: "private"})
  end

  test "maps indexed tool lifecycle and decodes safe aliases" do
    encoded = ToolName.encode("mcp:backplane:web::search")

    assert {:tool_call_delta, 2, "call-1", "mcp:backplane:web::search", ""} =
             EventMapper.map_event(%StreamEvent{
               type: :tool_call_start,
               index: 2,
               call_id: "call-1",
               name: encoded
             })

    assert {:tool_call_delta, 2, "call-1", "mcp:backplane:web::search", "{\"q\":"} =
             EventMapper.map_event(%StreamEvent{
               type: :tool_call_delta,
               index: 2,
               call_id: "call-1",
               name: encoded,
               arguments_delta: "{\"q\":"
             })

    assert {:tool_call_done, 2, "call-1", "mcp:backplane:web::search", %{"q" => "x"}} =
             EventMapper.map_event(%StreamEvent{
               type: :tool_call_done,
               index: 2,
               call_id: "call-1",
               name: encoded,
               content: %{"q" => "x"}
             })
  end

  test "projects provider state into a JSON-safe ordered host event" do
    state = %ProviderState{
      source_profile: "primary",
      source_protocol: "anthropic",
      kind: "anthropic_signed_thinking",
      affinity: %Affinity{
        profile: "primary",
        protocol: "anthropic",
        endpoint: "https://api.example",
        model: "claude-test"
      },
      payload: %{"thinking" => "private", "signature" => "signed"}
    }

    assert {:provider_state, projected} =
             EventMapper.map_event(%StreamEvent{type: :provider_state, provider_state: state})

    assert projected["kind"] == "anthropic_signed_thinking"
    assert projected["affinity"]["model"] == "claude-test"
    assert projected["payload"]["signature"] == "signed"
  end

  test "usage and terminal events do not terminate the host stream" do
    usage = %Usage{mode: :delta, status: :partial, source: "openai", output_tokens: 2}
    assert {:usage, ^usage} = EventMapper.map_event(%StreamEvent{type: :usage, usage: usage})
    assert :ignore = EventMapper.map_event(%StreamEvent{type: :terminal, stop_reason: :stop})
  end

  test "maps canonical errors and rejects missing content" do
    error = Backplane.AiProtocol.Error.invalid!("bad frame")
    assert {:error, ^error} = EventMapper.map_event(%StreamEvent{type: :error, error: error})

    assert {:error, %Error{kind: :incompatible}} =
             EventMapper.map_event(%StreamEvent{type: :content})
  end

  test "rejects unsupported canonical content instead of silently dropping it" do
    image = %ContentBlock{
      type: :image,
      data: %{"source" => "base64", "media_type" => "image/png", "data" => "AA=="}
    }

    assert {:error, %Error{kind: :incompatible}} =
             EventMapper.map_event(%StreamEvent{type: :content, content: image})
  end
end
