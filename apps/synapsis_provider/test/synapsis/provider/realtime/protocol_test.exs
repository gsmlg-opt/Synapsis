defmodule Synapsis.Provider.Realtime.ProtocolTest do
  use ExUnit.Case, async: true
  alias Synapsis.Provider.Realtime.Protocol

  test "Realtime configuration uses PCM and leaves response scheduling to Conversation" do
    update = Protocol.session_update(%{voice: "marin", voice_turn_detection: "server_vad"})
    assert update.session.type == "realtime"
    assert update.session.audio.input.format == %{type: "audio/pcm", rate: 24_000}
    assert update.session.audio.input.turn_detection.create_response == false
    assert update.session.audio.input.turn_detection.interrupt_response == false
    assert %{silence_duration_ms: 700} = update.session.audio.input.turn_detection
  end

  test "the server silence window does not apply to semantic or manual turn detection" do
    agent = %{voice: "marin", voice_turn_detection: "semantic_vad"}

    assert %{type: "semantic_vad"} =
             Protocol.session_update(agent).session.audio.input.turn_detection

    refute Map.has_key?(
             Protocol.session_update(agent).session.audio.input.turn_detection,
             :silence_duration_ms
           )

    manual = %{agent | voice_turn_detection: "manual"}
    assert Protocol.session_update(manual).session.audio.input.turn_detection == nil
  end

  test "only a completed response returns calls, deduplicated by original call ID" do
    call = %{
      "type" => "function_call",
      "status" => "completed",
      "call_id" => "call-1",
      "name" => "native",
      "arguments" => ~s({"value":1})
    }

    response = %{"status" => "completed", "output" => [call, call]}

    assert {:ok, [%{id: "call-1", name: "synapsis::native", arguments: %{"value" => 1}}], _} =
             Protocol.finish(response, %{"native" => "synapsis::native"}, nil)

    assert {:ok, [], %{type: :response_interrupted, reason: "barge_in"}} =
             Protocol.finish(%{response | "status" => "cancelled"}, %{}, "barge_in")

    assert {:ok, [], %{type: :response_interrupted, reason: "barge_in"}} =
             Protocol.finish(response, %{}, "barge_in")

    assert {:error, :invalid_function_call} =
             Protocol.finish(
               %{response | "output" => [call, %{call | "arguments" => "{}"}]},
               %{"native" => "native"},
               nil
             )
  end

  test "a rejected tool batch can preserve completed assistant speech and usage" do
    speech = %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "id" => "item_speech",
      "content" => [%{"type" => "output_audio", "transcript" => "Already spoken"}]
    }

    malformed = %{"type" => "function_call", "id" => "item_tool", "status" => "incomplete"}

    response = %{
      "id" => "resp_reply",
      "status" => "completed",
      "output" => [speech, malformed],
      "usage" => %{"input_tokens" => 20}
    }

    assert {:error, :invalid_function_call} = Protocol.finish(response, %{}, nil)

    assert {[^speech],
            %{
              type: :response_completed,
              message: %{content: [%{type: :spoken_audio, text: "Already spoken"}]},
              usage: %{input_tokens: 20}
            }} = Protocol.finish_without_calls(response)
  end

  test "a mixed native catalog only advertises callable Realtime functions" do
    grammar = %{
      type: "custom",
      name: "apply_patch",
      description: "Apply a freeform patch",
      format: %{"type" => "grammar", "syntax" => "lark", "definition" => "start: patch"}
    }

    schema = %{"type" => "object", "properties" => %{}}
    function = %{name: "edit", description: "Edit a file", parameters: schema}

    assert {[%{type: "function", name: "edit", parameters: ^schema}], %{"edit" => "edit"}} =
             Protocol.tools([grammar, function])

    assert {[], %{}} = Protocol.tools([%{grammar | type: :custom}])
  end

  test "Realtime tools keep the object properties and omit unsupported root constraints" do
    properties = %{
      "content" => %{"type" => ["string", "null"]},
      "binary" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
    }

    schema = %{
      "type" => "object",
      "properties" => properties,
      "required" => ["id"],
      "additionalProperties" => false,
      "anyOf" => [%{"required" => ["content"]}, %{"required" => ["binary"]}]
    }

    {[%{name: wire_name, parameters: wire_schema}], names} =
      Protocol.tools([
        %{name: "mcp::attachment", description: "Save attachment", parameters: schema}
      ])

    assert names[wire_name] == "mcp::attachment"
    assert wire_schema == Map.delete(schema, "anyOf")
  end
end
