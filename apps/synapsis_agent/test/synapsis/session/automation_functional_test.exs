defmodule Synapsis.Session.AutomationFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Sessions

  @moduletag :tmp_dir

  test "idle completion persists one assistant turn without requesting a provider and survives rehydrate",
       ctx do
    fixture = fixture(ctx.tmp_dir)
    id = fixture.session.id
    assert {:ok, meta} = Store.get_meta(id)

    edited =
      Map.merge(meta, %{title: "Human title", config: Map.put(meta.config, "retained", "yes")})

    assert :ok = Store.put_meta(id, edited)

    assert {:ok, %{status: :delivered, message_id: message_id}} =
             Sessions.append_automation_result(id, "自动化完成\nexact bytes  ")

    assert {:ok, [turn]} = Store.list_turns(id)
    assert turn.id == message_id
    assert turn.role == "assistant"
    assert turn.parts == [%{type: "text", text: "自动化完成\nexact bytes  "}]
    assert {:ok, current} = Store.get_meta(id)
    assert current.title == edited.title
    assert current.config == edited.config
    assert current.updated_at != edited.updated_at
    assert Agent.get(fixture.requests, & &1) == []
    assert_receive {"done", %{automation_result: ^message_id}}, 5_000

    assert :ok = DynamicSupervisor.stop_session(id)
    assert {:ok, %{source: :durable, context: block}} = Sessions.automation_context(id)
    assert block == "Recent conversation:\n- Assistant: 自动化完成 exact bytes"
    assert Registry.lookup(Synapsis.Session.Registry, id) == []
    assert :ok = Sessions.ensure_running(id)
    assert :ok = Worker.send_message(id, "Recall completion")
    assert_receive {:automation_request, 0, request, _}, 5_000
    assert {"assistant", "自动化完成\nexact bytes  "} in wire_messages(request)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert length(Agent.get(fixture.requests, & &1)) == 1
  end

  test "active completion defers without changing canonical history and precedes the queued prompt",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold_first: true)
    id = fixture.session.id
    assert :ok = Worker.send_message(id, "Active source prompt")
    assert_receive {:automation_request, 0, first, handler}, 5_000
    assert {"user", "Active source prompt"} in wire_messages(first)

    assert {:ok, %{source: :live, context: block}} = Sessions.automation_context(id)
    assert block == "Recent conversation:\n- User: Active source prompt"
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_state, data} = :sys.get_state(worker)
    assert %{root: root} = SessionAdapter.automation_snapshot(data.runtime_pid)
    before = Backplane.AgentRuntime.Conversation.status(root).messages

    assert {:ok, %{status: :deferred, message_id: message_id}} =
             Sessions.append_automation_result(id, "Result between turns")

    assert Backplane.AgentRuntime.Conversation.status(root).messages == before
    assert {:ok, [only_user]} = Store.list_turns(id)
    assert only_user.role == "user"
    assert :ok = Worker.send_message(id, "Queued source prompt")
    send(handler, :continue_automation)
    assert_receive {:automation_request, 1, following, _}, 10_000

    assert wire_messages(following) == [
             {"user", "Active source prompt"},
             {"assistant", "fixture reply 0"},
             {"assistant", "Result between turns"},
             {"user", "Queued source prompt"}
           ]

    assert_receive {"done", %{automation_result: ^message_id}}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert {:ok, :idle} =
             wait_for(fn ->
               case Worker.public_status(id) do
                 {:ok, %{runtime: %{active: false}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)

    assert {:ok, turns} = Store.list_turns(id)
    assert Enum.count(turns, &(&1.id == message_id)) == 1
    assert length(Agent.get(fixture.requests, & &1)) == 2
    assert {:ok, %{context: final}} = Sessions.automation_context(id)
    assert length(Regex.scan(~r/Result between turns/, final)) == 1
  end

  test "acknowledged announcement survives worker replacement and keeps its run identity", ctx do
    fixture = fixture(ctx.tmp_dir, stream_first: true)
    id = fixture.session.id
    run_id = Ecto.UUID.generate()
    assert :ok = Worker.send_message(id, "Held source prompt")
    assert_receive {:automation_request, 0, _, handler}, 5_000
    assert_receive {"text_delta", %{text: "正在回答"}}, 5_000

    assert {:ok, %{status: :deferred, message_id: message_id}} =
             Sessions.append_automation_result(id, "Durable result", run_id: run_id)

    assert [%{kind: "assistant_completion", id: ^message_id, status: "queued"}] =
             Synapsis.Session.PendingInputStore.list(id)

    assert :ok = DynamicSupervisor.stop_session(id)
    send(handler, :abandon_automation)
    assert :ok = Sessions.ensure_running(id)

    assert {:ok, :delivered} =
             wait_for(fn ->
               case Store.list_turns(id) do
                 {:ok, turns} ->
                   if Enum.any?(turns, &(&1.id == message_id)),
                     do: {:ok, :delivered},
                     else: :retry

                 _ ->
                   :retry
               end
             end)

    # Replace again after the append committed: only the durable receipt remains.
    assert :ok = DynamicSupervisor.stop_session(id)
    assert :ok = Sessions.ensure_running(id)

    assert {:ok, %{status: :delivered, message_id: ^message_id}} =
             Sessions.append_automation_result(id, "Durable result", run_id: run_id)

    assert {:ok, turns} = Store.list_turns(id)
    assert Enum.count(turns, &(&1.id == message_id)) == 1
    assert length(Agent.get(fixture.requests, & &1)) == 1

    assert {:ok, %{status: :delivered, message_id: other_id}} =
             Sessions.append_automation_result(id, "Durable result", run_id: Ecto.UUID.generate())

    refute other_id == message_id
    assert length(Agent.get(fixture.requests, & &1)) == 1
  end

  test "replacement preserves an unresolved final transaction fence", ctx do
    fixture = fixture(ctx.tmp_dir)
    id = fixture.session.id
    assert :ok = DynamicSupervisor.stop_session(id)
    run_id = Ecto.UUID.generate()

    assert {:ok, input} =
             Synapsis.Session.PendingInputStore.append_assistant(
               id,
               "Unknown commit",
               "#{id}/#{run_id}/announce"
             )

    assert {:ok, snapshot = {:present, [entry], _}} = Store.read_pending_inputs(id)

    claimed =
      entry |> Map.put(:status, "inflight") |> Map.put(:completion_claim, Ecto.UUID.generate())

    assert :ok = Store.compare_put_pending_inputs(id, snapshot, [claimed])
    assert :ok = Sessions.ensure_running(id)

    assert {:error, :unknown_outcome} =
             Sessions.append_automation_result(id, "Unknown commit", run_id: run_id)

    assert {:ok, []} = Store.list_turns(id)
    assert [%{status: "inflight", id: message_id}] = Synapsis.Session.PendingInputStore.list(id)
    assert message_id == input.id
    assert Agent.get(fixture.requests, & &1) == []
    assert :ok = DynamicSupervisor.stop_session(id)
    assert :ok = Sessions.ensure_running(id)

    assert {:error, :unknown_outcome} =
             Sessions.append_automation_result(id, "Unknown commit", run_id: run_id)

    assert {:ok, []} = Store.list_turns(id)
    assert Agent.get(fixture.requests, & &1) == []
  end

  test "a final commit with its task reply withheld recovers only the existing receipt", ctx do
    fixture = fixture(ctx.tmp_dir)
    id = fixture.session.id
    assert :ok = DynamicSupervisor.stop_session(id)
    run_id = Ecto.UUID.generate()

    assert {:ok, input} =
             Synapsis.Session.PendingInputStore.append_assistant(
               id,
               "Committed before reply",
               "#{id}/#{run_id}/announce"
             )

    turn = %{id: input.id, role: "assistant", parts: [%{type: "text", text: input.content}]}
    owner = self()

    task =
      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
        result = Synapsis.Session.PendingInputStore.complete_assistant(id, input.id, turn)
        send(owner, {:commit_before_reply, self(), result})

        receive do
          :release_commit_reply -> result
        after
          5_000 -> raise "commit reply handshake timed out"
        end
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:commit_before_reply, task_pid, {:ok, 0, _}}, 5_000
    assert :ok = Sessions.ensure_running(id)

    assert {:ok, %{status: :delivered, message_id: message_id}} =
             Sessions.append_automation_result(id, "Committed before reply", run_id: run_id)

    assert message_id == input.id
    assert {:ok, [^turn]} = Store.list_turns(id)
    assert Agent.get(fixture.requests, & &1) == []
    send(task_pid, :release_commit_reply)
    assert {:ok, 0, _} = Task.await(task, 5_000)
  end

  test "explicit append callers retain independent message identities", ctx do
    fixture = fixture(ctx.tmp_dir)
    id = fixture.session.id

    assert {:ok, %{status: :delivered, message_id: first}} =
             Sessions.append_automation_result(id, "same")

    assert {:ok, %{status: :delivered, message_id: second}} =
             Sessions.append_automation_result(id, "same")

    refute first == second
    assert {:ok, [%{id: ^first}, %{id: ^second}]} = Store.list_turns(id)
    assert Agent.get(fixture.requests, & &1) == []
  end

  test "storage rejection does not acknowledge an announcement", ctx do
    fixture = fixture(ctx.tmp_dir)
    id = fixture.session.id
    assert {:ok, %{status: :delivered}} = Sessions.append_automation_result(id, "initial")
    assert :ok = Store.put_value(id, "pending_inputs", :invalid)

    assert {:error, :invalid_pending_inputs} =
             Sessions.append_automation_result(id, "rejected", run_id: Ecto.UUID.generate())

    assert {:ok, [%{parts: [%{text: "initial"}]}]} = Store.list_turns(id)
    assert Agent.get(fixture.requests, & &1) == []
  end

  test "live context includes visible streaming text without persisting it early", ctx do
    fixture = fixture(ctx.tmp_dir, stream_first: true)
    id = fixture.session.id
    assert :ok = Worker.send_message(id, "Current question")
    assert_receive {:automation_request, 0, _, handler}, 5_000
    assert_receive {"text_delta", %{text: "正在回答"}}, 5_000
    assert {:ok, %{source: :live, context: block}} = Sessions.automation_context(id)
    assert block == "Recent conversation:\n- User: Current question\n- Assistant: 正在回答"
    assert {:ok, [user]} = Store.list_turns(id)
    assert user.role == "user"
    send(handler, :continue_automation)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert {:ok, %{context: completed}} = Sessions.automation_context(id)
    assert length(Regex.scan(~r/正在回答/, completed)) == 1
    assert length(Agent.get(fixture.requests, & &1)) == 1
  end

  defp fixture(root, opts \\ []) do
    owner = self()
    http = Gaoxy.Test.open()
    name = "automation-source-#{Ecto.UUID.generate()}"
    requests = start_supervised!({Agent, fn -> [] end})

    assert :ok =
             Synapsis.Provider.Registry.register(name, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
             })

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: name,
               model: "automation-source-model",
               tools: [],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      index =
        Agent.get_and_update(requests, fn values -> {length(values), values ++ [request]} end)

      send(owner, {:automation_request, index, request, self()})
      stream? = index == 0 and Keyword.get(opts, :stream_first, false)

      conn =
        if stream? do
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} =
            Plug.Conn.chunk(
              conn,
              "data: #{Formata.JSON.encode!(DeterministicProvider.text_chunk("正在回答"))}\n\n"
            )

          conn
        else
          conn
        end

      finish? =
        if index == 0 and (Keyword.get(opts, :hold_first, false) or stream?) do
          receive do
            :continue_automation -> true
            :abandon_automation when stream? -> false
          after
            10_000 -> raise "automation fixture handshake timed out"
          end
        else
          true
        end

      if finish? do
        chunks =
          if stream?, do: [], else: [DeterministicProvider.text_chunk("fixture reply #{index}")]

        DeterministicProvider.send_sse(
          conn,
          chunks ++ [DeterministicProvider.finish_chunk("stop")]
        )
      else
        conn
      end
    end)

    assert {:ok, session} =
             Sessions.create(name, %{
               agent: name,
               config: %{
                 "workspace_path" => root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

    on_exit(fn ->
      Sessions.delete(session.id)
      Synapsis.AgentConfigs.delete(agent)
      Synapsis.Provider.Registry.unregister(name)
    end)

    %{session: session, requests: requests}
  end

  defp wire_messages(request) do
    request["input"]
    |> Enum.reject(&(&1["role"] == "system"))
    |> Enum.map(fn message ->
      content =
        case message["content"] do
          text when is_binary(text) ->
            text

          blocks when is_list(blocks) ->
            Enum.map_join(blocks, "", fn
              %{"type" => type, "text" => text} when type in ~w(input_text output_text) -> text
              _ -> ""
            end)
        end

      {message["role"], content}
    end)
  end
end
