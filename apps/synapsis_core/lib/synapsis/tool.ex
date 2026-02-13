defmodule Synapsis.Tool do
  @moduledoc """
  Canonical behaviour for tool implementations.

  Provides `name/0`, `description/0`, `parameters/0`, `execute/2` callbacks
  and an optional `side_effects/0` callback for declaring what effects a tool produces.

  ## Usage

      defmodule MyTool do
        use Synapsis.Tool

        @impl true
        def name, do: "my_tool"

        @impl true
        def description, do: "Does something useful."

        @impl true
        def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

        @impl true
        def execute(input, context), do: {:ok, "done"}

        @impl true
        def side_effects, do: [:file_changed]
      end
  """

  @type context :: %{
          optional(:project_path) => String.t(),
          optional(:session_id) => String.t(),
          optional(:working_dir) => String.t(),
          optional(:permissions) => map(),
          optional(atom()) => term()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(input :: map(), context :: context()) ::
              {:ok, String.t()} | {:error, term()}
  @callback side_effects() :: [atom()]

  @optional_callbacks [side_effects: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour Synapsis.Tool

      @impl Synapsis.Tool
      def side_effects, do: []

      defoverridable side_effects: 0
    end
  end
end
