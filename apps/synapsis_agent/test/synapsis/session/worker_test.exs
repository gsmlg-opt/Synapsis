defmodule Synapsis.Session.WorkerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Session.Worker
  alias Synapsis.Session.Worker.IOHandler

  # ADR-006 C4: sessions live in the Concord-backed Session.Store, not Ecto.
  defp build_session(attrs) do
    %Session{}
    |> Session.changeset(
      Map.merge(%{provider: "anthropic", model: "test-model", agent: "main"}, attrs)
    )
    |> Ecto.Changeset.apply_changes()
    |> Map.put(:id, Ecto.UUID.generate())
  end

  defp persist_session(attrs) do
    session = build_session(attrs)
    :ok = Session.Store.put_meta(session.id, Session.to_meta(session))
    session
  end

  test "cancel resets engine to idle and bumps epoch" do
    session = persist_session(%{status: "streaming"})

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

    {:next_state, next_state, new_state, _actions} =
      Worker.handle_event(:cast, :cancel, :generating, state)

    assert next_state == :idle, "cancel must land the machine back in :idle"
    assert new_state.epoch != old_epoch, "epoch must be bumped on cancel"
    assert new_state.stream_ref == nil
    assert new_state.pending_tool_count == 0
    assert map_size(new_state.tool_tasks) == 0
    assert new_state.engine_node == graph.start
    assert Worker.engine_ready?(new_state), "engine must be re-parked at :receive after cancel"
    {:ok, meta} = Session.Store.get_meta(session.id)
    assert Session.from_meta(meta).status == "idle"
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
    session = build_session(%{status: "streaming"})

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

    new_state = IOHandler.handle_dispatch_tools(classified, opts, state)

    # Already-executed tool skipped: count stays 0, no new tasks
    assert new_state.pending_tool_count == 0
    assert map_size(new_state.tool_tasks) == 0
  end

  test "handle_dispatch_tools tracks fresh tool_use_ids in executed_tool_ids" do
    session = build_session(%{status: "streaming"})

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

    new_state = IOHandler.handle_dispatch_tools(classified, opts, state)

    assert MapSet.member?(new_state.executed_tool_ids, new_tool_id)
  end

  # --- ADR-008: explicit session states ---

  describe "derive_state/1" do
    defp base_data do
      {:ok, graph} = CodingLoop.build()

      %Worker{
        session_id: "test",
        graph: graph,
        engine_node: :receive,
        engine_state: %{awaiting_input: true},
        engine_ctx: %{},
        epoch: 1
      }
    end

    test ":idle when the engine is parked at :receive" do
      assert Worker.derive_state(base_data()) == :idle
    end

    test ":generating when a provider stream is in flight" do
      assert Worker.derive_state(%{base_data() | stream_ref: make_ref()}) == :generating
    end

    test ":executing_tools when tool tasks are outstanding" do
      assert Worker.derive_state(%{base_data() | pending_tool_count: 2}) == :executing_tools
    end

    test ":awaiting_approval when permission decisions are pending" do
      data = %{base_data() | pending_approvals: MapSet.new(["tool-1"])}
      assert Worker.derive_state(data) == :awaiting_approval
    end

    test ":awaiting_approval wins over :generating (approval blocks the turn)" do
      data = %{
        base_data()
        | pending_approvals: MapSet.new(["tool-1"]),
          stream_ref: make_ref()
      }

      assert Worker.derive_state(data) == :awaiting_approval
    end

    test ":busy when the engine waits on a non-input node" do
      data = %{base_data() | engine_node: :llm_stream, engine_state: %{}}
      assert Worker.derive_state(data) == :busy
    end

    test ":query_loop when an assistant-mode turn is running" do
      task = %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {__MODULE__, :noop, 0}}
      data = %{base_data() | execution_mode: :query_loop, query_loop_task: task}
      assert Worker.derive_state(data) == :query_loop
    end
  end

  describe "busy-prompt policy (harness ADR-0006)" do
    test "send_message is rejected outside :idle in graph mode" do
      {:ok, graph} = CodingLoop.build()

      data = %Worker{
        session_id: "test",
        graph: graph,
        engine_node: :llm_stream,
        engine_state: %{},
        engine_ctx: %{},
        epoch: 1,
        execution_mode: :graph
      }

      from = {self(), make_ref()}

      {:keep_state_and_data, actions} =
        Worker.handle_event({:call, from}, {:send_message, "hi", []}, :generating, data)

      assert {:reply, ^from, {:error, {:engine_not_ready, :llm_stream}}} =
               List.keyfind(actions, :reply, 0)
    end
  end
end
