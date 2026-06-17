defmodule Synapsis.Session.WorkerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Session.PendingInputStore
  alias Synapsis.Session.Worker
  alias Synapsis.Session.Worker.{IOHandler, Persistence}
  alias Synapsis.{Message, Part}

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
    test "send_message queues outside :idle in graph mode" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :llm_stream,
        engine_state: CodingLoop.initial_state(%{session_id: session.id}),
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :graph,
        stream_ref: make_ref()
      }

      from = {self(), make_ref()}

      assert {:next_state, :generating, _new_data, actions} =
               Worker.handle_event(
                 {:call, from},
                 {:send_message, "queued", []},
                 :generating,
                 data
               )

      assert {:reply, ^from, :ok} = Enum.find(actions, &match?({:reply, ^from, :ok}, &1))

      assert [%{content: "queued", status: "queued"}] =
               PendingInputStore.queued_prompts(session.id)

      assert [] = Message.list_by_session(session.id)
    end

    test "steer_message/2 public API exists" do
      assert function_exported?(Worker, :steer_message, 2)
    end

    test "steer_message stores advisory text while graph is running" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :tool_execute,
        engine_state: CodingLoop.initial_state(%{session_id: session.id}),
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :graph,
        pending_tool_count: 1
      }

      from = {self(), make_ref()}

      assert {:next_state, :executing_tools, _new_data, actions} =
               Worker.handle_event(
                 {:call, from},
                 {:steer_message, "prefer small patch"},
                 :executing_tools,
                 data
               )

      assert {:reply, ^from, :ok} = Enum.find(actions, &match?({:reply, ^from, :ok}, &1))

      assert [%{content: "prefer small patch", status: "queued"}] =
               PendingInputStore.queued_steers(session.id)

      assert [] = Message.list_by_session(session.id)
    end

    test "steer_message starts a turn while graph is idle" do
      session = persist_session(%{status: "idle"})
      {:ok, graph} = CodingLoop.build()

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :receive,
        engine_state:
          CodingLoop.initial_state(%{session_id: session.id})
          |> Map.put(:awaiting_input, true),
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :graph
      }

      from = {self(), make_ref()}

      assert {:next_state, _state, _new_data, actions} =
               Worker.handle_event(
                 {:call, from},
                 {:steer_message, "start from idle"},
                 :idle,
                 data
               )

      assert {:reply, ^from, :ok} = Enum.find(actions, &match?({:reply, ^from, :ok}, &1))

      assert [%Message{role: "user", parts: [%Part.Text{content: "start from idle"}]}] =
               Message.list_by_session(session.id)

      assert [] = PendingInputStore.queued_steers(session.id)
    end

    test "cancel preserves queued prompts and cancels queued steers" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()
      assert {:ok, _prompt} = PendingInputStore.append_prompt(session.id, "next turn", [])
      assert {:ok, _steer} = PendingInputStore.append_steer(session.id, "forget that")

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :llm_stream,
        engine_state: CodingLoop.initial_state(%{session_id: session.id}),
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :graph,
        stream_ref: make_ref()
      }

      assert {:next_state, :idle, _new_data, _actions} =
               Worker.handle_event(:cast, :cancel, :generating, data)

      assert [%{content: "next turn", status: "queued"}] =
               PendingInputStore.queued_prompts(session.id)

      assert [%{content: "forget that", status: "cancelled"}] =
               PendingInputStore.list(session.id) |> Enum.filter(&(&1.kind == "steer"))
    end

    test "send_message queues while query-loop turn is running" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()
      task = %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {__MODULE__, :noop, 0}}

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :receive,
        engine_state: %{awaiting_input: true},
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :query_loop,
        query_loop_task: task
      }

      from = {self(), make_ref()}

      assert {:next_state, :query_loop, new_data, actions} =
               Worker.handle_event(
                 {:call, from},
                 {:send_message, "queued for later", []},
                 :query_loop,
                 data
               )

      assert new_data.query_loop_task == task
      assert {:reply, ^from, :ok} = Enum.find(actions, &match?({:reply, ^from, :ok}, &1))

      assert [%{content: "queued for later", status: "queued"}] =
               PendingInputStore.queued_prompts(session.id)

      assert [] = Message.list_by_session(session.id)
    end

    test "step_engine starts next queued prompt when graph is parked at receive" do
      session = persist_session(%{status: "idle"})
      {:ok, graph} = CodingLoop.build()
      assert {:ok, queued} = PendingInputStore.append_prompt(session.id, "queued turn", [])

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :receive,
        engine_state:
          CodingLoop.initial_state(%{session_id: session.id})
          |> Map.put(:awaiting_input, true),
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :graph,
        executed_tool_ids: MapSet.new(["previous-tool"])
      }

      new_data = Worker.step_engine(data)

      assert [%Message{role: "user", parts: [%Part.Text{content: "queued turn"}]}] =
               Message.list_by_session(session.id)

      assert [%{id: id, status: "consumed"}] = PendingInputStore.list(session.id)
      assert id == queued.id
      assert new_data.executed_tool_ids == MapSet.new()

      assert_receive {"input_started", %{id: ^id, kind: "prompt", content: "queued turn"}}
    end

    test "failed graph queued prompt start is requeued" do
      session = persist_session(%{status: "idle"})
      {:ok, graph} = CodingLoop.build()
      queued = put_malformed_queued_prompt(session.id, "bad graph prompt")

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :receive,
        engine_state:
          CodingLoop.initial_state(%{session_id: session.id})
          |> Map.put(:awaiting_input, true),
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :graph
      }

      result =
        try do
          {:ok, Worker.step_engine(data)}
        rescue
          error -> {:raised, error}
        end

      assert {:ok, _new_data} = result

      assert [%{id: id, content: "bad graph prompt", status: "queued"}] =
               PendingInputStore.queued_prompts(session.id)

      assert id == queued.id
      assert [] = Message.list_by_session(session.id)
    end

    test "failed query-loop queued prompt start is requeued" do
      session = persist_session(%{status: "idle"})
      {:ok, graph} = CodingLoop.build()
      queued = put_malformed_queued_prompt(session.id, "bad query prompt")
      task_ref = make_ref()
      task = %Task{ref: task_ref, pid: self(), owner: self(), mfa: {__MODULE__, :noop, 0}}

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :receive,
        engine_state: %{awaiting_input: true},
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :query_loop,
        query_loop_task: task
      }

      result =
        try do
          {:ok,
           Worker.handle_event(
             :info,
             {task_ref, {:ok, :completed, %{}}},
             :query_loop,
             data
           )}
        rescue
          error -> {:raised, error}
        end

      assert {:ok, {:next_state, :idle, _new_data, _actions}} = result

      assert [%{id: id, content: "bad query prompt", status: "queued"}] =
               PendingInputStore.queued_prompts(session.id)

      assert id == queued.id
      assert [] = Message.list_by_session(session.id)
    end

    test "query-loop task down starts next queued prompt" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()
      assert {:ok, queued} = PendingInputStore.append_prompt(session.id, "after crash", [])
      task_ref = make_ref()
      task = %Task{ref: task_ref, pid: self(), owner: self(), mfa: {__MODULE__, :noop, 0}}

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

      data = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :receive,
        engine_state: %{awaiting_input: true},
        engine_ctx: %{},
        epoch: System.monotonic_time(),
        execution_mode: :query_loop,
        query_loop_task: task
      }

      assert {:next_state, :query_loop, new_data, _actions} =
               Worker.handle_event(
                 :info,
                 {:DOWN, task_ref, :process, self(), :crash},
                 :query_loop,
                 data
               )

      assert %Task{} = new_data.query_loop_task
      assert new_data.query_loop_task.ref != task_ref

      assert [%Message{role: "user", parts: [%Part.Text{content: "after crash"}]}] =
               Message.list_by_session(session.id)

      assert [%{id: id, status: "consumed"}] = PendingInputStore.list(session.id)
      assert id == queued.id
      assert_receive {"input_started", %{id: ^id, kind: "prompt", content: "after crash"}}

      Task.shutdown(new_data.query_loop_task, :brutal_kill)
    end
  end

  describe "regenerate" do
    test "truncates the transcript to before the target assistant message" do
      session = persist_session(%{status: "idle"})
      {:ok, _q1} = Message.append(session.id, text_message("user", "q1"))
      {:ok, _a1} = Message.append(session.id, text_message("assistant", "a1"))
      {:ok, _q2} = Message.append(session.id, text_message("user", "q2"))
      {:ok, a2} = Message.append(session.id, text_message("assistant", "a2"))

      assert {:ok, "q2"} = Persistence.truncate_to_regenerate(session.id, a2.id)

      assert [
               %Message{role: "user", parts: [%Part.Text{content: "q1"}]},
               %Message{role: "assistant", parts: [%Part.Text{content: "a1"}]},
               %Message{role: "user", parts: [%Part.Text{content: "q2"}]}
             ] = Message.list_by_session(session.id)
    end

    test "regenerating an earlier reply discards every later turn" do
      session = persist_session(%{status: "idle"})
      {:ok, _q1} = Message.append(session.id, text_message("user", "q1"))
      {:ok, a1} = Message.append(session.id, text_message("assistant", "a1"))
      {:ok, _q2} = Message.append(session.id, text_message("user", "q2"))
      {:ok, _a2} = Message.append(session.id, text_message("assistant", "a2"))

      assert {:ok, "q1"} = Persistence.truncate_to_regenerate(session.id, a1.id)

      assert [%Message{role: "user", parts: [%Part.Text{content: "q1"}]}] =
               Message.list_by_session(session.id)
    end

    test "rejects a non-assistant target without mutating the transcript" do
      session = persist_session(%{status: "idle"})
      {:ok, q1} = Message.append(session.id, text_message("user", "q1"))
      {:ok, _a1} = Message.append(session.id, text_message("assistant", "a1"))

      assert {:error, :not_assistant_message} =
               Persistence.truncate_to_regenerate(session.id, q1.id)

      assert [%Message{role: "user"}, %Message{role: "assistant"}] =
               Message.list_by_session(session.id)
    end

    test "rejects an unknown message id" do
      session = persist_session(%{status: "idle"})
      {:ok, _a1} = Message.append(session.id, text_message("assistant", "a1"))

      assert {:error, :message_not_found} =
               Persistence.truncate_to_regenerate(session.id, Ecto.UUID.generate())
    end

    test "rejects when no user message precedes the target" do
      session = persist_session(%{status: "idle"})
      {:ok, a1} = Message.append(session.id, text_message("assistant", "a1"))

      assert {:error, :no_user_context} =
               Persistence.truncate_to_regenerate(session.id, a1.id)
    end

    test "the worker rejects regenerate outside :idle" do
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
        Worker.handle_event({:call, from}, {:regenerate, "msg-1"}, :generating, data)

      assert {:reply, ^from, {:error, {:engine_not_ready, :llm_stream}}} =
               List.keyfind(actions, :reply, 0)
    end
  end

  describe "session checkpoints" do
    test "push_checkpoint captures worker and message state" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()
      {:ok, _message} = Message.append(session.id, text_message("user", "before edit"))

      state = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :tool_execute,
        engine_state: %{phase: :before},
        engine_ctx: %{context: :before},
        epoch: 1,
        execution_mode: :graph,
        executed_tool_ids: MapSet.new(["tool-before"])
      }

      from = {self(), make_ref()}

      {:next_state, _next_state, new_state, actions} =
        Worker.handle_event({:call, from}, {:push_checkpoint, "before patch"}, :busy, state)

      assert {:reply, ^from, {:ok, checkpoint_id}} = List.keyfind(actions, :reply, 0)
      assert is_binary(checkpoint_id)

      assert [%{id: ^checkpoint_id, reason: "before patch", turn_count: 1}] =
               new_state.checkpoints

      # GUARDRAILS NEVER #1: the stack is in-memory only — no separate durable key.
      assert Session.Store.get_value(session.id, "checkpoints", :missing) == :missing
    end

    test "rollback_checkpoint restores worker state and durable messages" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()
      {:ok, _message} = Message.append(session.id, text_message("user", "before edit"))

      before_state = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :build_prompt,
        engine_state: %{phase: :before},
        engine_ctx: %{context: :before},
        epoch: 1,
        execution_mode: :graph,
        executed_tool_ids: MapSet.new(["tool-before"])
      }

      {:next_state, _next_state, checkpointed_state, _actions} =
        Worker.handle_event(
          {:call, {self(), make_ref()}},
          {:push_checkpoint, "before patch"},
          :busy,
          before_state
        )

      {:ok, _message} = Message.append(session.id, text_message("assistant", "bad patch"))

      after_state = %{
        checkpointed_state
        | engine_node: :tool_execute,
          engine_state: %{phase: :after},
          engine_ctx: %{context: :after},
          executed_tool_ids: MapSet.new(["tool-after"])
      }

      from = {self(), make_ref()}

      {:next_state, _next_state, rolled_back_state, actions} =
        Worker.handle_event(
          {:call, from},
          {:rollback_checkpoint, "patch failed"},
          :executing_tools,
          after_state
        )

      assert {:reply, ^from, {:ok, checkpoint_id}} = List.keyfind(actions, :reply, 0)
      assert is_binary(checkpoint_id)
      assert rolled_back_state.engine_node == :build_prompt
      assert rolled_back_state.engine_state == %{phase: :before}
      assert %{context: :before, checkpoint_rollback: rollback} = rolled_back_state.engine_ctx
      assert rollback.reason == "patch failed"
      assert rolled_back_state.executed_tool_ids == MapSet.new(["tool-before"])
      assert rolled_back_state.checkpoints == []

      assert [
               %Message{role: "user", parts: [%Part.Text{content: "before edit"}]},
               %Message{role: "system", parts: [%Part.Text{content: correction}]}
             ] = Message.list_by_session(session.id)

      assert correction =~ "Checkpoint rollback"
      assert correction =~ "patch failed"
      refute correction =~ "bad patch"
    end

    test "rollback_checkpoint reports empty stack without changing state" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()

      state = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :tool_execute,
        engine_state: %{phase: :current},
        engine_ctx: %{context: :current},
        epoch: 1,
        execution_mode: :graph
      }

      from = {self(), make_ref()}

      {:keep_state_and_data, actions} =
        Worker.handle_event(
          {:call, from},
          {:rollback_checkpoint, "patch failed"},
          :executing_tools,
          state
        )

      assert {:reply, ^from, {:error, :no_checkpoint}} = List.keyfind(actions, :reply, 0)
    end

    @tag :tmp_dir
    test "rollback_checkpoint restores git workspace files", %{tmp_dir: tmp_dir} do
      init_git_repo!(tmp_dir)
      File.write!(Path.join(tmp_dir, "src.txt"), "clean\n")
      git!(tmp_dir, ["add", "."])
      git!(tmp_dir, ["commit", "-q", "-m", "baseline"])

      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()
      {:ok, _message} = Message.append(session.id, text_message("user", "edit src.txt"))

      state = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :build_prompt,
        engine_state: %{phase: :before},
        engine_ctx: %{},
        epoch: 1,
        execution_mode: :graph,
        project_path: tmp_dir
      }

      {:next_state, _next, checkpointed, _actions} =
        Worker.handle_event(
          {:call, {self(), make_ref()}},
          {:push_checkpoint, "before patch"},
          :busy,
          state
        )

      assert [%{workspace_ref: %{head: head}}] = checkpointed.checkpoints
      assert head =~ ~r/^[0-9a-f]{40}$/

      File.write!(Path.join(tmp_dir, "src.txt"), "corrupted by failed patch\n")

      {:next_state, _next, _rolled_back, actions} =
        Worker.handle_event(
          {:call, {self(), make_ref()}},
          {:rollback_checkpoint, "patch failed"},
          :executing_tools,
          checkpointed
        )

      assert {:reply, _from, {:ok, _id}} = List.keyfind(actions, :reply, 0)
      assert File.read!(Path.join(tmp_dir, "src.txt")) == "clean\n"

      assert [_user, %Message{role: "system", parts: [%Part.Text{content: correction}]}] =
               Message.list_by_session(session.id)

      assert correction =~ "Workspace files were restored"
    end

    test "stream violation with a checkpoint rolls back and resumes the engine" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()
      {:ok, _message} = Message.append(session.id, text_message("user", "hello"))

      state = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: graph.start,
        engine_state: CodingLoop.initial_state(%{session_id: session.id}),
        engine_ctx: %{},
        epoch: 1,
        execution_mode: :graph
      }

      {:next_state, _next, checkpointed, _actions} =
        Worker.handle_event(
          {:call, {self(), make_ref()}},
          {:push_checkpoint, "before stream"},
          :busy,
          state
        )

      {:ok, _message} = Message.append(session.id, text_message("assistant", "forbidden output"))

      {:next_state, _next, rolled_back, _actions} =
        Worker.handle_event(
          :info,
          {:provider_error, {:stream_violation, "[redacted 6-byte pattern]"}},
          :generating,
          checkpointed
        )

      assert rolled_back.checkpoints == []

      assert [
               %Message{role: "user"},
               %Message{role: "system", parts: [%Part.Text{content: correction}]}
             ] = Message.list_by_session(session.id)

      assert correction =~ "stream guard violation"
      refute correction =~ "forbidden output"
    end

    test "stream violation without a checkpoint falls through to provider error handling" do
      session = persist_session(%{status: "streaming"})
      {:ok, graph} = CodingLoop.build()

      state = %Worker{
        session_id: session.id,
        session: session,
        graph: graph,
        engine_node: :llm_stream,
        engine_state: CodingLoop.initial_state(%{session_id: session.id}),
        engine_ctx: %{},
        epoch: 1,
        execution_mode: :graph
      }

      {:next_state, _next, new_state, _actions} =
        Worker.handle_event(
          :info,
          {:provider_error, {:stream_violation, "[redacted]"}},
          :generating,
          state
        )

      assert new_state.engine_ctx[:stream_error] == {:stream_violation, "[redacted]"}
    end
  end

  defp init_git_repo!(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@synapsis.local"])
    git!(dir, ["config", "user.name", "Synapsis Test"])
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end

  defp text_message(role, content) do
    %Message{role: role, parts: [%Part.Text{content: content}], token_count: 1}
  end

  defp put_malformed_queued_prompt(session_id, content) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    input = %{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      kind: "prompt",
      status: "queued",
      content: content,
      image_parts: "invalid image parts",
      inserted_at: now,
      updated_at: now
    }

    :ok = Session.Store.put_value(session_id, "pending_inputs", [input])
    input
  end
end
