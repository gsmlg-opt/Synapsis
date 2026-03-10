defmodule Synapsis.Tool do
  @moduledoc """
  Canonical behaviour for tool implementations.

  Provides `name/0`, `description/0`, `parameters/0`, `execute/2` callbacks
  and optional callbacks for declaring side effects, permission levels,
  categories, versions, and enabled status.

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

        @impl true
        def permission_level, do: :write

        @impl true
        def category, do: :filesystem
      end
  """

  @type permission_level :: :none | :read | :write | :execute | :destructive

  @type category ::
          :filesystem
          | :search
          | :execution
          | :web
          | :planning
          | :orchestration
          | :interaction
          | :session
          | :notebook
          | :computer
          | :swarm

  @type context :: %{
          optional(:project_path) => String.t(),
          optional(:session_id) => String.t(),
          optional(:working_dir) => String.t(),
          optional(:permissions) => map(),
          optional(:session_pid) => pid(),
          optional(:agent_mode) => :build | :plan,
          optional(:parent_agent) => pid() | nil,
          optional(atom()) => term()
        }

  # Required callbacks
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(input :: map(), context :: context()) ::
              {:ok, String.t()} | {:error, term()}

  # Optional callbacks
  @callback side_effects() :: [atom()]
  @callback permission_level() :: permission_level()
  @callback category() :: category()
  @callback version() :: String.t()
  @callback enabled?() :: boolean()

  @optional_callbacks [
    side_effects: 0,
    permission_level: 0,
    category: 0,
    version: 0,
    enabled?: 0
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour Synapsis.Tool

      @impl Synapsis.Tool
      def side_effects, do: []

      @impl Synapsis.Tool
      def permission_level, do: :read

      @impl Synapsis.Tool
      def category, do: :filesystem

      @impl Synapsis.Tool
      def version, do: "1.0.0"

      @impl Synapsis.Tool
      def enabled?, do: true

      defoverridable side_effects: 0,
                     permission_level: 0,
                     category: 0,
                     version: 0,
                     enabled?: 0
    end
  end
end
