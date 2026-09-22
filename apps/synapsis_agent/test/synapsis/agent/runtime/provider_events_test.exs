defmodule Synapsis.Agent.Runtime.ProviderEventsTest do
  use ExUnit.Case, async: true
  alias Synapsis.Agent.Runtime.ProviderEvents

  test "retains signed reasoning, text, usage semantics and interleaved tool identities" do
    provider_state = %{
      "payload" => %{"thinking" => "thought", "signature" => "s"},
      "affinity" => %{"model" => "m"}
    }

    usage = %Backplane.AiProtocol.Usage{
      mode: :delta,
      status: :partial,
      source: "openai",
      output_tokens: 3
    }

    events = [
      {:reasoning_delta, "thought"},
      {:provider_state, provider_state},
      {:text_delta, "Answer"},
      {:usage, usage},
      {:tool_call_delta, 1, "b", "second", ""},
      {:tool_call_delta, 0, "a", "first", "{"},
      {:tool_call_delta, 0, nil, nil, "}"},
      {:tool_call_done, 0, nil, nil, %{}},
      {:tool_call_done, 1, "b", "second", %{}}
    ]

    {mapped, state} =
      Enum.reduce(events, {[], ProviderEvents.new()}, fn event, {acc, state} ->
        assert {:ok, output, next} = ProviderEvents.push(state, event)
        {acc ++ output, next}
      end)

    assert %{type: :usage_updated, usage: Map.from_struct(usage)} in mapped

    assert {:ok, %{message: %{content: [reasoning, text, first, second]}}} =
             ProviderEvents.finish(state)

    assert reasoning == %{type: :reasoning, text: "thought", provider_states: [provider_state]}
    assert text == %{type: :text, text: "Answer"}
    assert {first.id, second.id} == {"a", "b"}
  end

  test "does not fabricate input for incomplete tools or accept reused IDs" do
    assert {:ok, _, state} =
             ProviderEvents.push(ProviderEvents.new(), {:tool_call_delta, 0, "c", "skill", "{"})

    assert {:error, _} = ProviderEvents.finish(state)
    assert {:error, _} = ProviderEvents.push(state, {:tool_call_done, 0, "changed", "skill", %{}})
    assert {:ok, _, done} = ProviderEvents.push(state, {:tool_call_done, 0, "c", "skill", %{}})
    assert {:error, _} = ProviderEvents.push(done, {:tool_call_done, 1, "c", "skill", %{}})
    assert {:error, _} = ProviderEvents.push(done, {:tool_call_done, 2, "d", "skill", "bad"})
    assert {:error, _} = ProviderEvents.push(done, :unknown)
  end

  test "unsigned reasoning after a signed block remains a separate replayable part" do
    assert {:ok, _, state} =
             ProviderEvents.push(ProviderEvents.new(), {:reasoning_delta, "signed"})

    assert {:ok, _, state} =
             ProviderEvents.push(state, {:provider_state, %{"payload" => "signature"}})

    assert {:ok, _, state} = ProviderEvents.push(state, {:reasoning_delta, "unsigned"})

    assert {:ok,
            %{message: %{content: [%{text: "signed", provider_states: [_]}, %{text: "unsigned"}]}}} =
             ProviderEvents.finish(state)
  end
end
