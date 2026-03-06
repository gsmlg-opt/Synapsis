defmodule Synapsis.Agent.Runtime.Node do
  @moduledoc """
  Behaviour for executable graph nodes.

  Each node receives the current workflow state and an immutable context map.
  The node returns one of:

  - `{:next, selector, state}`: continue to the next node
  - `{:end, state}`: finish the run
  - `{:wait, state}`: pause until `Runner.resume/2` is called
  """

  @type workflow_state :: map()
  @type context :: map()
  @type selector :: atom()

  @callback run(workflow_state(), context()) ::
              {:next, selector(), workflow_state()}
              | {:end, workflow_state()}
              | {:wait, workflow_state()}
end
