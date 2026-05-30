defmodule Synapsis.Session.WorkerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.{Repo, Session}
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Session.Worker

  test "cancel resets engine to idle and bumps epoch" do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        provider: "anthropic",
        model: "test-model",
        agent: "main",
        status: "streaming"
      })
      |> Repo.insert()

    {:ok, graph} = CodingLoop.build()
    old_epoch = System.monotonic_time()

    state = %Worker{
      session_id: session.id,
      session: session,
      graph: graph,
      engine_node: :llm_stream,
      engine_state: CodingLoop.initial_state(%{session_id: session.id}),
      engine_ctx: %{},
      epoch: old_epoch,
      execution_mode: :graph,
      pending_tool_count: 2,
      tool_tasks: MapSet.new([:fake_ref])
    }

    {:noreply, new_state, _timeout} = Worker.handle_cast(:cancel, state)

    assert new_state.epoch != old_epoch, "epoch must be bumped on cancel"
    assert new_state.stream_ref == nil
    assert new_state.pending_tool_count == 0
    assert MapSet.size(new_state.tool_tasks) == 0
    assert new_state.engine_node == graph.start
    assert Repo.get!(Session, session.id).status == "idle"
  end

  test "engine_ready? is true only when parked at :receive with awaiting_input" do
    {:ok, graph} = CodingLoop.build()

    base = %Worker{
      session_id: "test",
      graph: graph,
      engine_node: :receive,
      engine_state: %{awaiting_input: true},
      engine_ctx: %{},
      epoch: 1
    }

    assert Worker.engine_ready?(base)
    refute Worker.engine_ready?(%{base | engine_node: :llm_stream})
    refute Worker.engine_ready?(%{base | engine_state: %{}})
  end
end
