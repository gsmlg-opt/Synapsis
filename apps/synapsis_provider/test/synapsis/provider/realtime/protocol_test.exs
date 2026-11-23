defmodule Synapsis.Provider.Realtime.ProtocolTest do
  use ExUnit.Case, async: true
  alias Synapsis.Provider.Realtime.Protocol

  test "Realtime configuration uses PCM and leaves response scheduling to Conversation" do
    update = Protocol.session_update(%{voice: "marin", voice_turn_detection: "server_vad"})
    assert update.session.type == "realtime"
    assert update.session.audio.input.format == %{type: "audio/pcm", rate: 24_000}
    assert update.session.audio.input.turn_detection.create_response == false
    assert update.session.audio.input.turn_detection.interrupt_response == false
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

    assert {:error, :invalid_function_call} =
             Protocol.finish(
               %{response | "output" => [call, %{call | "arguments" => "{}"}]},
               %{"native" => "native"},
               nil
             )
  end
end
