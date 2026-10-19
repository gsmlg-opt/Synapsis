defmodule Synapsis.Provider.RequestHistoryTest do
  use ExUnit.Case, async: true

  alias Synapsis.Part
  alias Synapsis.Provider.MessageMapper

  @origin %{model: "old-model", provider_name: "primary", endpoint: "https://api.example"}

  test "explicit model switching projects portable content and preserves original history" do
    messages = history()
    original = :erlang.term_to_binary(messages)

    assert {:ok, wire} =
             MessageMapper.build_request(:openai, messages, [], %{
               model: "new-model",
               provider_name: "secondary",
               endpoint: "https://other.example/v1",
               history_projection: :portable
             })

    assert [
             %{"role" => "user", "content" => [%{"text" => "Find it"}]},
             %{
               "role" => "assistant",
               "content" => [%{"text" => "Searching"}],
               "tool_calls" => [call]
             },
             %{"role" => "tool", "tool_call_id" => "call-1", "content" => "Found it"}
           ] = wire["messages"]

    assert call["id"] == "call-1"
    assert call["function"]["arguments"] == ~s({"q":"query"})
    assert :erlang.term_to_binary(messages) == original
    refute inspect(wire) =~ "private reasoning"
    refute inspect(wire) =~ "opaque-signature"
  end

  test "compatible signed state survives the portable projection unchanged" do
    opts = Map.put(@origin, :history_projection, :portable)
    assert {:ok, wire} = MessageMapper.build_request(:anthropic, history(), [], opts)
    assistant = Enum.find(wire["messages"], &(&1["role"] == "assistant"))

    assert %{
             "type" => "thinking",
             "thinking" => "private reasoning",
             "signature" => "opaque-signature"
           } in assistant["content"]
  end

  test "strict requests still reject a model-bound state at a changed origin" do
    assert {:error, %Backplane.AiProtocol.Error{kind: :incompatible}} =
             MessageMapper.build_request(:anthropic, history(), [], %{
               @origin
               | model: "new-model"
             })
  end

  test "portable projection still rejects signatures missing their origin" do
    messages = [
      %{
        role: "assistant",
        parts: [%Part.Reasoning{content: "private", signature: "unattributed"}]
      }
    ]

    assert {:error, %Backplane.AiProtocol.Error{kind: :incompatible}} =
             MessageMapper.build_request(:openai, messages, [], %{
               model: "new-model",
               history_projection: :portable
             })
  end

  test "messages made empty by removing incompatible state are omitted" do
    messages = [
      %{role: "assistant", parts: [%Part.Reasoning{provider_states: [provider_state()]}]},
      %{role: "user", parts: [%Part.Text{content: "Continue"}]}
    ]

    assert {:ok, %{"messages" => [%{"role" => "user", "content" => [%{"text" => "Continue"}]}]}} =
             MessageMapper.build_request(:openai, messages, [], %{
               model: "new-model",
               history_projection: :portable
             })
  end

  test "portable projection rejects an orphan tool result rather than inventing a call" do
    assert {:error, %Backplane.AiProtocol.Error{kind: :invalid_request}} =
             MessageMapper.build_request(
               :openai,
               [
                 %{role: "user", parts: [%Part.ToolResult{tool_use_id: "missing", content: "ok"}]}
               ],
               [],
               %{model: "new-model", history_projection: :portable}
             )
  end

  defp history do
    [
      %{role: "user", parts: [%Part.Text{content: "Find it"}]},
      %{
        role: "assistant",
        parts: [
          %Part.Reasoning{content: "private reasoning", provider_states: [provider_state()]},
          %Part.Text{content: "Searching"},
          %Part.ToolUse{tool: "search", tool_use_id: "call-1", input: %{"q" => "query"}}
        ]
      },
      %{role: "user", parts: [%Part.ToolResult{tool_use_id: "call-1", content: "Found it"}]}
    ]
  end

  defp provider_state do
    %{
      source_profile: "primary",
      source_protocol: "anthropic",
      kind: "anthropic_signed_thinking",
      affinity: %{
        profile: "primary",
        protocol: "anthropic",
        endpoint: "https://api.example",
        model: "old-model"
      },
      payload: %{
        "type" => "thinking",
        "thinking" => "private reasoning",
        "signature" => "opaque-signature"
      }
    }
  end
end
