defmodule Synapsis.Agent.Runtime.ProviderMessagesTest do
  use ExUnit.Case, async: true
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Part.{Image, Reasoning, Text, ToolResult, ToolUse}

  test "round trips domain history including images, signed reasoning and tool identity" do
    state = %{
      "kind" => "signed",
      "affinity" => %{"model" => "m"},
      "payload" => %{"signature" => "s"}
    }

    parts = [
      %Text{content: "hello"},
      %Image{media_type: "image/png", data: "AA==", path: "/image.png"},
      %Reasoning{content: "thought", signature: "s", provider_states: [state]},
      %ToolUse{tool_use_id: "call-1", tool: "skill", input: %{"name" => "review"}}
    ]

    messages = [
      %Synapsis.Message{role: "assistant", parts: parts},
      %Synapsis.Message{
        role: "user",
        parts: [%ToolResult{tool_use_id: "call-1", content: "body"}]
      }
    ]

    assert {:ok, runtime} = ProviderMessages.from_host(messages)
    assert [%{role: :assistant}, %{role: :tool, tool_call_id: "call-1"}] = runtime

    assert {:ok,
            [%{parts: ^parts}, %{parts: [%ToolResult{content: "body", tool_use_id: "call-1"}]}]} =
             ProviderMessages.to_host(runtime)
  end

  test "converts runtime error results to host errors without leaking inspected internals" do
    assert {:ok, [%{parts: [%ToolResult{is_error: true, content: "Tool execution failed"}]}]} =
             ProviderMessages.to_host([
               %{role: :tool, tool_call_id: "c", result: %{is_error: true, error: :denied}}
             ])
  end

  test "unsupported history fails explicitly" do
    assert {:error, _} = ProviderMessages.to_host([%{role: :user, content: [%{type: :audio}]}])

    assert {:error, _} =
             ProviderMessages.from_host([%{role: "unknown", parts: [%Text{content: "x"}]}])

    assert {:error, _} =
             ProviderMessages.from_host([%{role: "user", parts: [%Synapsis.Part.File{}]}])
  end
end
