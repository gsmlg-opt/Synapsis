defmodule Synapsis.Session.NativeQuestionRuntimeTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} = ctx do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    {:ok, _} =
      Synapsis.AgentConfigs.update(harness.agent_config, %{tools: ["synapsis::ask_user"]})

    raw = Store.get_value(harness.session.id, "permission")
    :ok = Store.put_value(harness.session.id, "permission", %{raw | mode: :interactive})
    SessionHarness.ensure_running!(harness.session.id)
    SessionHarness.subscribe!(harness.session.id)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      has_result = Enum.any?(request["messages"], &(&1["role"] == "tool"))

      chunks =
        if has_result do
          [
            DeterministicProvider.text_chunk("question complete"),
            DeterministicProvider.finish_chunk("stop")
          ]
        else
          [
            DeterministicProvider.tool_call_chunk(
              ToolName.encode("synapsis::ask_user"),
              "question-one",
              Map.merge(
                %{"question" => "Which workspace should I use?"},
                if(ctx[:choices], do: %{"options" => ctx.choices}, else: %{})
              )
            ),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    %{harness: harness, id: harness.session.id}
  end

  test "free-text native question waits in Conversation and closes only after acknowledged answer",
       ctx do
    assert :ok = Worker.send_message(ctx.id, "Ask a question")
    assert_receive {:ask_user, ref, _}, 5_000

    assert [%{ref: ^ref, question: "Which workspace should I use?", options: nil}] =
             Worker.snapshot(ctx.id).user_questions

    assert Worker.snapshot(ctx.id).runtime_permissions == []
    assert :ok = Worker.answer_question(ctx.id, ref, "Use the current workspace")
    assert_receive {:ask_user_closed, ^ref}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 5_000

    assert [
             %ToolResult{
               is_error: false,
               content: "Use the current workspace",
               projection: projection
             }
           ] = results(ctx.id)

    assert projection["result"]["structured"]["answer"] == "Use the current workspace"
    assert Worker.snapshot(ctx.id).user_questions == []
    assert {:error, :question_not_pending} = Worker.answer_question(ctx.id, ref, "duplicate")
  end

  test "autonomous mode refuses a question before native tool intent", ctx do
    raw = Store.get_value(ctx.id, "permission")
    :ok = Store.put_value(ctx.id, "permission", %{raw | mode: :autonomous})
    assert :ok = Worker.send_message(ctx.id, "Try an autonomous question")
    assert_receive {:run_event, %{type: "session.completed"}}, 5_000
    refute_receive {:ask_user, _, _}
    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert tool_intents(ctx.id) == []
  end

  test "permission changes while waiting prevent using the answered result", ctx do
    assert :ok = Worker.send_message(ctx.id, "Ask before policy changes")
    assert_receive {:ask_user, ref, _}, 5_000
    raw = Store.get_value(ctx.id, "permission")

    :ok =
      Store.put_value(ctx.id, "permission", %{
        raw
        | tool_overrides: %{"synapsis::ask_user" => :deny}
      })

    assert :ok = Worker.answer_question(ctx.id, ref, "This answer must be discarded")
    assert_receive {:ask_user_closed, ^ref}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 5_000
    assert [%ToolResult{is_error: true, content: content}] = results(ctx.id)
    refute content =~ "This answer must be discarded"
  end

  test "cancelling a waiting native question clears it and rejects late answers", ctx do
    assert :ok = Worker.send_message(ctx.id, "Ask then cancel")
    assert_receive {:ask_user, ref, _}, 5_000
    assert :ok = Worker.cancel(ctx.id)
    assert_receive {:ask_user_closed, ^ref}, 5_000
    assert {:error, :question_not_pending} = Worker.answer_question(ctx.id, ref, "too late")
    assert Worker.snapshot(ctx.id).user_questions == []
  end

  @tag choices: [%{"label" => "Current", "description" => "Keep this workspace"}]
  test "choice metadata remains public and answers may be free text", ctx do
    assert :ok = Worker.send_message(ctx.id, "Ask with a choice")
    assert_receive {:ask_user, ref, _}, 5_000
    assert [%{ref: ^ref, options: options}] = Worker.snapshot(ctx.id).user_questions
    assert options == ctx.choices
    assert :ok = Worker.answer_question(ctx.id, ref, "Use a different workspace")
    assert_receive {:run_event, %{type: "session.completed"}}, 5_000
    assert [%ToolResult{is_error: false, content: "Use a different workspace"}] = results(ctx.id)
  end

  test "invalid and foreign replies leave the native question available", ctx do
    assert :ok = Worker.send_message(ctx.id, "Ask then validate replies")
    assert_receive {:ask_user, ref, _}, 5_000

    for response <- [nil, "", " \t", <<255>>, String.duplicate("x", 32_769)] do
      assert {:error, :invalid_response} = Worker.answer_question(ctx.id, ref, response)
    end

    assert {:error, :question_not_pending} =
             Worker.answer_question(ctx.id, Ecto.UUID.generate(), "foreign")

    assert [%{ref: ^ref}] = Worker.snapshot(ctx.id).user_questions
    assert :ok = Worker.answer_question(ctx.id, ref, "accepted")
    assert_receive {:run_event, %{type: "session.completed"}}, 5_000
    assert [%ToolResult{is_error: false, content: "accepted"}] = results(ctx.id)
  end

  defp results(id),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        result = %ToolResult{} <- message.parts,
        do: result
      )

  defp tool_intents(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)
    {:ok, aggregate} = Synapsis.Runtime.Store.load(state.store.namespace, state.run_id)
    aggregate.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))
  end
end
