defmodule Synapsis.Agent.Runtime.CheckpointStoreTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Runtime.{CheckpointStore, Graph}

  defmodule FinishNode do
    @behaviour Synapsis.Agent.Runtime.Node
    def run(state, _ctx), do: {:end, state}
  end

  test "stores and retrieves checkpoints" do
    run_id = "checkpoint-store-" <> Integer.to_string(System.unique_integer([:positive]))

    graph = %Graph{
      nodes: %{finish: FinishNode},
      edges: %{finish: :end},
      start: :finish
    }

    assert :ok =
             CheckpointStore.put(%{
               run_id: run_id,
               graph: graph,
               node: :finish,
               status: :waiting,
               state: %{step: 1},
               ctx: %{approved: false}
             })

    assert {:ok, checkpoint} = CheckpointStore.get(run_id)
    assert checkpoint.status == :waiting
    assert checkpoint.state.step == 1
    assert checkpoint.ctx.approved == false

    listed_ids = CheckpointStore.list(run_id: run_id) |> Enum.map(& &1.run_id)
    assert run_id in listed_ids
  end
end
