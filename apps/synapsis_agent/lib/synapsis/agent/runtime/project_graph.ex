defmodule Synapsis.Agent.Runtime.ProjectGraph do
  @moduledoc """
  Runtime adapter graph for `Synapsis.Agent.Behaviour`.

  It maps the existing behaviour contract:
  `route -> execute -> summarize`
  into runtime nodes.
  """

  alias Synapsis.Agent.Memory.SummaryStore
  alias Synapsis.Agent.Runtime.{Graph, Node, Runner}

  @type runtime_state :: %{
          required(:work_item) => Synapsis.Agent.WorkItem.t(),
          required(:behaviour) => module(),
          required(:behaviour_state) => term(),
          optional(:route_plan) => map(),
          optional(:execution_result) => map(),
          optional(:summary) => map(),
          optional(:outcome) => map()
        }

  @spec graph() :: Graph.t()
  def graph do
    %Graph{
      nodes: %{
        route: __MODULE__.Nodes.Route,
        execute: __MODULE__.Nodes.Execute,
        summarize: __MODULE__.Nodes.Summarize
      },
      edges: %{
        route: %{ok: :execute},
        execute: %{ok: :summarize},
        summarize: :end
      },
      start: :route
    }
  end

  @spec run(Synapsis.Agent.WorkItem.t(), module(), term(), keyword()) ::
          {:ok, Runner.snapshot()} | {:error, term(), Runner.snapshot() | nil}
  def run(work_item, behaviour, behaviour_state, opts \\ []) do
    runtime_state = %{
      work_item: work_item,
      behaviour: behaviour,
      behaviour_state: behaviour_state
    }

    Runner.run(graph(), runtime_state, opts)
  end

  defmodule Nodes.Route do
    @moduledoc false
    @behaviour Node

    @impl true
    def run(
          %{work_item: work_item, behaviour: behaviour, behaviour_state: behaviour_state} = state,
          _ctx
        ) do
      case behaviour.route(work_item, behaviour_state) do
        {:ok, route_plan, next_behaviour_state} ->
          {:next, :ok,
           state
           |> Map.put(:route_plan, route_plan)
           |> Map.put(:behaviour_state, next_behaviour_state)}

        {:error, reason, failed_behaviour_state} ->
          {:end, failure(state, reason, failed_behaviour_state)}

        {:error, reason} ->
          {:end, failure(state, reason, behaviour_state)}
      end
    end

    defp failure(state, reason, behaviour_state) do
      state
      |> Map.put(:behaviour_state, behaviour_state)
      |> Map.put(:outcome, %{status: :error, reason: reason})
    end
  end

  defmodule Nodes.Execute do
    @moduledoc false
    @behaviour Node

    @impl true
    def run(
          %{
            work_item: work_item,
            behaviour: behaviour,
            behaviour_state: behaviour_state,
            route_plan: route_plan
          } = state,
          _ctx
        ) do
      case behaviour.execute(work_item, route_plan, behaviour_state) do
        {:ok, execution_result, next_behaviour_state} ->
          {:next, :ok,
           state
           |> Map.put(:execution_result, execution_result)
           |> Map.put(:behaviour_state, next_behaviour_state)}

        {:error, reason, failed_behaviour_state} ->
          {:end, failure(state, reason, failed_behaviour_state)}

        {:error, reason} ->
          {:end, failure(state, reason, behaviour_state)}
      end
    end

    defp failure(state, reason, behaviour_state) do
      state
      |> Map.put(:behaviour_state, behaviour_state)
      |> Map.put(:outcome, %{status: :error, reason: reason})
    end
  end

  defmodule Nodes.Summarize do
    @moduledoc false
    @behaviour Node

    @impl true
    def run(
          %{
            work_item: work_item,
            behaviour: behaviour,
            behaviour_state: behaviour_state,
            execution_result: execution_result,
            route_plan: route_plan
          } = state,
          _ctx
        ) do
      case behaviour.summarize(work_item, execution_result, behaviour_state) do
        {:ok, summary, next_behaviour_state} ->
          case SummaryStore.put(summary) do
            :ok ->
              {:end,
               state
               |> Map.put(:summary, summary)
               |> Map.put(:behaviour_state, next_behaviour_state)
               |> Map.put(:outcome, %{
                 status: :ok,
                 route: route_plan,
                 result: execution_result
               })}

            {:error, reason} ->
              {:end,
               state
               |> Map.put(:behaviour_state, next_behaviour_state)
               |> Map.put(:outcome, %{status: :error, reason: reason})}
          end

        {:error, reason, failed_behaviour_state} ->
          {:end, failure(state, reason, failed_behaviour_state)}

        {:error, reason} ->
          {:end, failure(state, reason, behaviour_state)}
      end
    end

    defp failure(state, reason, behaviour_state) do
      state
      |> Map.put(:behaviour_state, behaviour_state)
      |> Map.put(:outcome, %{status: :error, reason: reason})
    end
  end
end
