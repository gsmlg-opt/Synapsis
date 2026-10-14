defmodule Synapsis.Session.Worker.UserQuestionsTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session.Worker
  alias Synapsis.Agent.Graphs.CodingLoop

  setup do
    session_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "ask_user_response:#{session_id}")

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    %{data: %Worker{session_id: session_id, epoch: 1}, owner: owner}
  end

  test "snapshot retains pending questions without exposing private process state", ctx do
    {ref, data} = register(ctx.data, ctx.owner)
    assert [%{ref: ^ref, question: "Which city?", options: nil} = question] = snapshot(data)
    assert Map.keys(question) |> Enum.sort() == [:options, :question, :ref]
    assert_receive {:ask_user, ^ref, %{session_id: session_id} = payload}
    assert session_id == data.session_id
    refute Map.has_key?(payload, :owner)
    refute Map.has_key?(payload, :deadline_ms)
    refute Map.has_key?(payload, :session_epoch)
  end

  test "answer dispatches only the current ref and removes it before replying", ctx do
    {ref, data} = register(ctx.data, ctx.owner)
    assert {:ok, data} = answer(data, ref, "Beijing")
    assert_receive {:user_response, ^ref, "Beijing"}
    assert_receive {:ask_user_closed, ^ref}
    assert [] == snapshot(data)
    assert {{:error, :question_not_pending}, _} = answer(data, ref, "Again")
    refute_receive {:user_response, ^ref, "Again"}
  end

  test "foreign refs and blank responses do not consume a question", ctx do
    {ref, data} = register(ctx.data, ctx.owner)

    assert {{:error, :question_not_pending}, _} =
             answer(%Worker{session_id: Ecto.UUID.generate()}, ref, "Other session")

    assert {{:error, :invalid_response}, data} = answer(data, ref, "  ")
    assert [%{ref: ^ref}] = snapshot(data)
    refute_receive {:user_response, ^ref, _}
  end

  test "expired questions cannot be answered even before their timer is handled", ctx do
    {ref, data} = register(ctx.data, ctx.owner, 10)
    assert_receive {:ask_user_expired, ^ref}, 1_000
    assert {{:error, :question_not_pending}, data} = answer(data, ref, "Too late")
    assert [] == snapshot(data)
    assert_receive {:ask_user_closed, ^ref}
    refute_receive {:user_response, ^ref, _}
  end

  test "waiting process death closes the question", ctx do
    {ref, data} = register(ctx.data, ctx.owner)
    Process.exit(ctx.owner, :kill)
    assert_receive {:DOWN, monitor, :process, owner, reason}, 1_000

    assert {:keep_state, data, _} =
             Worker.handle_event(:info, {:DOWN, monitor, :process, owner, reason}, :idle, data)

    assert [] == snapshot(data)
    assert_receive {:ask_user_closed, ^ref}
  end

  test "tool closure clears the question and duplicate public notifications are ignored", ctx do
    {ref, data} = register(ctx.data, ctx.owner)
    assert_receive {:ask_user, ^ref, payload}

    assert {:keep_state, data, _} =
             Worker.handle_event(:info, {:ask_user, ref, payload}, :idle, data)

    assert {:keep_state, data, _} =
             Worker.handle_event(:info, {:ask_user_closed, ref}, :idle, data)

    assert [] == snapshot(data)
  end

  test "cancel closes questions and releases their waiting owners", ctx do
    session = %Synapsis.Session{id: ctx.data.session_id, status: "streaming"}
    :ok = Synapsis.Session.Store.put_meta(session.id, Synapsis.Session.to_meta(session))
    {ref, data} = register(%{ctx.data | session: session, execution_mode: :query_loop}, self())
    assert {:next_state, _, data, _} = Worker.handle_event(:cast, :cancel, :query_loop, data)
    assert [] == snapshot(data)
    assert_receive {:ask_user_cancelled, ^ref}
    assert_receive {:ask_user_closed, ^ref}
  end

  test "late questions from a cancelled graph turn are rejected and release their owner", ctx do
    session = %Synapsis.Session{id: ctx.data.session_id, status: "streaming"}
    :ok = Synapsis.Session.Store.put_meta(session.id, Synapsis.Session.to_meta(session))
    {:ok, graph} = CodingLoop.build()

    data = %{
      ctx.data
      | session: session,
        graph: graph,
        engine_node: :llm_stream,
        engine_state: CodingLoop.initial_state(%{session_id: session.id}),
        engine_ctx: %{},
        execution_mode: :graph
    }

    assert {:next_state, :idle, data, _} =
             Worker.handle_event(:cast, :cancel, :generating, data)

    assert data.epoch != ctx.data.epoch
    {ref, data} = register(data, self(), 10_000, ctx.data.epoch)
    assert [] == snapshot(data)
    assert_receive {:ask_user_cancelled, ^ref}
    assert_receive {:ask_user_closed, ^ref}
    refute_receive {:ask_user, ^ref, _}
    assert {{:error, :question_not_pending}, _} = answer(data, ref, "Too late")
  end

  test "legacy questions without an epoch remain answerable", ctx do
    {ref, data} = register(ctx.data, ctx.owner, 10_000, nil)
    assert [%{ref: ^ref}] = snapshot(data)
    assert {:ok, _} = answer(data, ref, "Legacy")
    assert_receive {:user_response, ^ref, "Legacy"}
  end

  defp register(data, owner, timeout \\ 10_000, epoch \\ :current) do
    ref = Ecto.UUID.generate()

    payload = %{
      ref: ref,
      question: "Which city?",
      options: nil,
      owner: owner,
      session_epoch: if(epoch == :current, do: data.epoch, else: epoch),
      deadline_ms: System.monotonic_time(:millisecond) + timeout
    }

    assert {:keep_state, data, _} =
             Worker.handle_event(:info, {:ask_user, ref, payload}, :idle, data)

    {ref, data}
  end

  defp snapshot(data) do
    from = {self(), make_ref()}
    assert {:keep_state, _, actions} = Worker.handle_event({:call, from}, :snapshot, :idle, data)
    {:reply, ^from, snapshot} = List.keyfind(actions, :reply, 0)
    snapshot.user_questions
  end

  defp answer(data, ref, response) do
    from = {self(), make_ref()}

    assert {:keep_state, data, actions} =
             Worker.handle_event({:call, from}, {:answer_question, ref, response}, :idle, data)

    {:reply, ^from, result} = List.keyfind(actions, :reply, 0)
    {result, data}
  end
end
