defmodule Synapsis.Agent.Nodes.ProcessResponseTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Agent.Nodes.ProcessResponse
  alias Synapsis.Message

  defp session_fixture do
    session =
      %Session{}
      |> Session.changeset(%{
        provider: "anthropic",
        model: "test",
        agent: "main",
        status: "streaming"
      })
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:id, Ecto.UUID.generate())

    :ok = Session.Store.put_meta(session.id, Session.to_meta(session))
    session
  end

  defp base_state(session_id, overrides) do
    Map.merge(
      %{
        session_id: session_id,
        pending_text: "",
        pending_tool_use: nil,
        pending_tool_input: "",
        pending_reasoning: "",
        pending_reasoning_signature: "",
        tool_uses: [],
        empty_completion_retries: 0
      },
      overrides
    )
  end

  test "routes :no_tools and persists an assistant message when text was produced" do
    session = session_fixture()
    state = base_state(session.id, %{pending_text: "here is your answer"})

    assert {:next, :no_tools, new_state} = ProcessResponse.run(state, %{})
    assert new_state.empty_completion_retries == 0
    assert [%Message{role: "assistant"}] = Message.list_by_session(session.id)
  end

  test "routes :has_tools when the response contains a tool call" do
    session = session_fixture()

    tool_use = %Synapsis.Part.ToolUse{
      tool: "bash",
      tool_use_id: "t1",
      input: %{},
      status: :pending
    }

    state = base_state(session.id, %{tool_uses: [tool_use], pending_tool_use: tool_use})

    assert {:next, :has_tools, _new_state} = ProcessResponse.run(state, %{})
  end

  test "an empty completion retries once before completing" do
    session = session_fixture()
    state = base_state(session.id, %{empty_completion_retries: 0})

    # First empty completion → retry (re-run the model).
    assert {:next, :retry, retried} = ProcessResponse.run(state, %{})
    assert retried.empty_completion_retries == 1
    assert Message.list_by_session(session.id) == []

    # Still empty after the retry → surface a system notice and complete.
    assert {:next, :no_tools, done} = ProcessResponse.run(retried, %{})
    assert done.empty_completion_retries == 0

    assert [%Message{role: "system", parts: [%Synapsis.Part.Text{content: notice}]}] =
             Message.list_by_session(session.id)

    assert notice =~ "without producing an answer"
  end
end
