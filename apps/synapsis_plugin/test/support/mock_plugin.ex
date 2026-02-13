defmodule SynapsisPlugin.Test.MockPlugin do
  @moduledoc "Mock plugin for testing the Server wrapper."
  use Synapsis.Plugin

  defstruct [:name, :counter, effects: []]

  @impl Synapsis.Plugin
  def init(config) do
    {:ok, %__MODULE__{name: config[:name] || "mock", counter: 0}}
  end

  @impl Synapsis.Plugin
  def tools(_state) do
    [
      %{
        name: "mock_echo",
        description: "Echoes input back.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string"}
          },
          "required" => ["text"]
        }
      },
      %{
        name: "mock_count",
        description: "Returns an incrementing counter.",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []}
      }
    ]
  end

  @impl Synapsis.Plugin
  def execute("mock_echo", input, state) do
    {:ok, input["text"] || "", state}
  end

  def execute("mock_count", _input, state) do
    new_state = %{state | counter: state.counter + 1}
    {:ok, "count: #{new_state.counter}", new_state}
  end

  def execute(_tool, _input, state) do
    {:error, "unknown tool", state}
  end

  @impl Synapsis.Plugin
  def handle_effect(effect, payload, state) do
    {:ok, %{state | effects: [{effect, payload} | state.effects]}}
  end
end
