defmodule Synapsis.Agent.Nodes.BuildPromptTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Nodes.BuildPrompt
  alias Synapsis.Session.PendingInputStore
  alias Synapsis.{Message, Part, Session}

  setup do
    session = persist_session()

    on_exit(fn ->
      Synapsis.Session.Store.delete_session(session.id)
    end)

    {:ok, session: session}
  end

  test "injects queued steer text into the next LLM request", %{session: session} do
    {:ok, _message} = append_user_message(session.id, "fix it")
    {:ok, steer} = PendingInputStore.append_steer(session.id, "focus on the current failing test")

    assert {:next, :default, new_state} = BuildPrompt.run(build_state(session), %{})

    assert new_state.request.system =~ "Mid-turn user guidance"
    assert new_state.request.system =~ "focus on the current failing test"
    assert [%{id: id, status: "consumed"}] = steer_inputs(session.id)
    assert id == steer.id

    assert [%Message{role: "user", parts: [%Part.Text{content: "fix it"}]}] =
             Message.list_by_session(session.id)
  end

  test "injects multiple queued steers in FIFO order", %{session: session} do
    {:ok, _message} = append_user_message(session.id, "fix it")
    {:ok, first} = PendingInputStore.append_steer(session.id, "first steer")
    {:ok, second} = PendingInputStore.append_steer(session.id, "second steer")

    assert {:next, :default, new_state} = BuildPrompt.run(build_state(session), %{})

    assert new_state.request.system =~ "Mid-turn user guidance:\nfirst steer\n\nsecond steer"

    assert [%{id: first_id, status: "consumed"}, %{id: second_id, status: "consumed"}] =
             steer_inputs(session.id)

    assert first_id == first.id
    assert second_id == second.id
  end

  test "does not add steer block when no steers are queued", %{session: session} do
    {:ok, _message} = append_user_message(session.id, "fix it")

    assert {:next, :default, new_state} = BuildPrompt.run(build_state(session), %{})

    refute new_state.request.system =~ "Mid-turn user guidance"
    assert [] = steer_inputs(session.id)
  end

  test "consumes blank queued steers without adding an empty guidance block", %{session: session} do
    {:ok, _message} = append_user_message(session.id, "fix it")
    {:ok, steer} = PendingInputStore.append_steer(session.id, "  \n  ")

    assert {:next, :default, new_state} = BuildPrompt.run(build_state(session), %{})

    refute new_state.request.system =~ "Mid-turn user guidance"
    assert [%{id: id, status: "consumed"}] = steer_inputs(session.id)
    assert id == steer.id
  end

  test "keeps queued steers queued when request construction raises", %{session: session} do
    {:ok, _message} = append_user_message(session.id, "fix it")
    {:ok, steer} = PendingInputStore.append_steer(session.id, "do not lose this")

    assert_raise FunctionClauseError, fn ->
      BuildPrompt.run(build_state(session, %{tools: :invalid}), %{})
    end

    assert [%{id: id, status: "queued"}] = steer_inputs(session.id)
    assert id == steer.id
  end

  defp persist_session do
    session =
      %Session{}
      |> Session.changeset(%{provider: "anthropic", model: "test-model", agent: "main"})
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:id, Ecto.UUID.generate())

    :ok = Session.Store.put_meta(session.id, Session.to_meta(session))

    session
  end

  defp append_user_message(session_id, content) do
    Message.append(session_id, %Message{role: "user", parts: [%Part.Text{content: content}]})
  end

  defp build_state(session) do
    build_state(session, %{})
  end

  defp build_state(session, overrides) do
    %{
      session_id: session.id,
      messages: [],
      user_input: nil,
      agent_config: %{provider: session.provider, name: session.agent, model: session.model}
    }
    |> update_in([:agent_config], &Map.merge(&1, overrides))
  end

  defp steer_inputs(session_id) do
    session_id
    |> PendingInputStore.list()
    |> Enum.filter(&(&1.kind == "steer"))
  end
end
