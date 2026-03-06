defmodule Synapsis.Agent.Behaviour do
  @moduledoc """
  LangGraph-style behavior contract for project agents.

  A behavior defines a deterministic node flow:
  `route -> execute -> summarize`.
  """

  alias Synapsis.Agent.WorkItem

  @type route_plan :: map()
  @type execution_result :: map()
  @type summary :: map()
  @type behaviour_state :: term()

  @callback init(project_id :: String.t(), opts :: map()) :: {:ok, behaviour_state()}

  @callback route(work_item :: WorkItem.t(), state :: behaviour_state()) ::
              {:ok, route_plan(), behaviour_state()}
              | {:error, term(), behaviour_state()}

  @callback execute(
              work_item :: WorkItem.t(),
              route_plan :: route_plan(),
              state :: behaviour_state()
            ) ::
              {:ok, execution_result(), behaviour_state()}
              | {:error, term(), behaviour_state()}

  @callback summarize(
              work_item :: WorkItem.t(),
              execution_result :: execution_result(),
              state :: behaviour_state()
            ) ::
              {:ok, summary(), behaviour_state()}
              | {:error, term(), behaviour_state()}
end
