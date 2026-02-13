defmodule Synapsis.Plugin do
  @moduledoc """
  Behaviour for plugin implementations.

  A plugin wraps an external process (MCP server, LSP server, or custom)
  and exposes its capabilities as tools in the Synapsis tool registry.
  """

  @type state :: term()
  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @doc "Initialize the plugin with config. Start external processes here."
  @callback init(config :: map()) :: {:ok, state()} | {:error, term()}

  @doc "Return the list of tools this plugin provides."
  @callback tools(state()) :: [tool_def()]

  @doc "Execute a tool by name."
  @callback execute(tool_name :: String.t(), input :: map(), state()) ::
              {:ok, String.t(), state()} | {:async, state()} | {:error, term(), state()}

  @doc "Handle a side effect broadcast (e.g., :file_changed)."
  @callback handle_effect(effect :: atom(), payload :: map(), state()) :: {:ok, state()}

  @doc "Handle arbitrary messages (e.g., Port data)."
  @callback handle_info(msg :: term(), state()) :: {:ok, state()}

  @doc "Clean up on termination."
  @callback terminate(reason :: term(), state()) :: :ok

  @optional_callbacks [handle_effect: 3, handle_info: 2, terminate: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour Synapsis.Plugin

      @impl Synapsis.Plugin
      def handle_effect(_effect, _payload, state), do: {:ok, state}

      @impl Synapsis.Plugin
      def handle_info(_msg, state), do: {:ok, state}

      @impl Synapsis.Plugin
      def terminate(_reason, _state), do: :ok

      defoverridable handle_effect: 3, handle_info: 2, terminate: 2
    end
  end
end
