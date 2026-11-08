defmodule Synapsis.Agent.Runtime.ProviderModelFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Runtime.ProviderEvents

  test "latest observed model is retained on the authoritative completed assistant message" do
    events = [
      {:resolved_model, "provider-observed-first"},
      {:text_delta, "{\"answer\":"},
      {:resolved_model, "provider-observed-final"},
      {:text_delta, "7}"}
    ]

    {mapped, state} =
      Enum.reduce(events, {[], ProviderEvents.new()}, fn event, {mapped, state} ->
        assert {:ok, output, next} = ProviderEvents.push(state, event)
        {mapped ++ output, next}
      end)

    assert mapped == [
             %{type: :content_text_delta, delta: "{\"answer\":"},
             %{type: :content_text_delta, delta: "7}"}
           ]

    assert {:ok,
            %{
              type: :response_completed,
              message: %{
                role: :assistant,
                content: [%{type: :text, text: "{\"answer\":7}"}],
                model: "provider-observed-final"
              }
            }} = ProviderEvents.finish(state)
  end
end
