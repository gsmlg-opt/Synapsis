defmodule Synapsis.Session.WorkerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.{Repo, Session}
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Session.Worker
  alias Synapsis.Session.Worker.IOHandler

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
      tool_tasks: %{make_ref() => "tool-id-1"}
    }

    {:noreply, new_state, _timeout} = Worker.handle_cast(:cancel, state)

    assert new_state.epoch != old_epoch, "epoch must be bumped on cancel"
    assert new_state.stream_ref == nil
    assert new_state.pending_tool_count == 0
    assert map_size(new_state.tool_tasks) == 0
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

  # --- A2: tool execution robustness ---

  test "handle_dispatch_tools skips already-executed tool_use_ids (idempotency guard)" do
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

    already_done_id = "tool-use-already-done"

    state = %Worker{
      session_id: session.id,
      session: session,
      graph: graph,
      engine_node: :tool_execute,
      engine_state: %{},
      engine_ctx: %{},
      epoch: System.monotonic_time(),
      execution_mode: :graph,
      pending_tool_count: 0,
      tool_tasks: %{},
      executed_tool_ids: MapSet.new([already_done_id])
    }

    tool_use = %Synapsis.Part.ToolUse{
      tool: "read_file",
      tool_use_id: already_done_id,
      input: %{"path" => "/tmp/test.txt"}
    }

    classified = [{:approved, tool_use}]
    opts = %{project_path: "/tmp", session_id: session.id, agent_id: "main"}

    {:noreply, new_state, _timeout} = IOHandler.handle_dispatch_tools(classified, opts, state)

    # Already-executed tool skipped: count stays 0, no new tasks
    assert new_state.pending_tool_count == 0
    assert map_size(new_state.tool_tasks) == 0
  end

  test "handle_dispatch_tools tracks fresh tool_use_ids in executed_tool_ids" do
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

    state = %Worker{
      session_id: session.id,
      session: session,
      graph: graph,
      engine_node: :tool_execute,
      engine_state: %{},
      engine_ctx: %{},
      epoch: System.monotonic_time(),
      execution_mode: :graph,
      pending_tool_count: 0,
      tool_tasks: %{},
      executed_tool_ids: MapSet.new()
    }

    new_tool_id = "new-tool-use-id"

    tool_use = %Synapsis.Part.ToolUse{
      tool: "read_file",
      tool_use_id: new_tool_id,
      input: %{"path" => "/tmp/test.txt"}
    }

    classified = [{:denied, tool_use}]
    opts = %{project_path: "/tmp", session_id: session.id, agent_id: "main"}

    {:noreply, new_state, _timeout} = IOHandler.handle_dispatch_tools(classified, opts, state)

    assert MapSet.member?(new_state.executed_tool_ids, new_tool_id)
  end
end
