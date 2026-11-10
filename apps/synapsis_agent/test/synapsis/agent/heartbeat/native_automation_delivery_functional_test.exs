defmodule Synapsis.Agent.Heartbeat.NativeAutomationDeliveryFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Routines
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.{Text, ToolResult}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Sessions

  @moduletag :tmp_dir
  @result "Automation completed\nexact bytes  "

  setup do
    assert {:ok, _} = wait_for_ready()
    :ok
  end

  test "current context and announce retain the submitted origin and actual provider overrides",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold_automation: true)
    source = source(fixture)
    other = source(fixture)
    seed_source(source)
    authored = "  Authored automation\nkeep exact bytes  "
    config = config(fixture, source, "current", "announce", %{"prompt" => authored})
    assert {:ok, submitted} = Routines.trigger({"routine", config["id"]})
    assert submitted.metadata["automation_origin"] == origin(fixture, source)
    assert submitted.metadata["retained"] == %{"trace" => "original"}
    assert submitted.provider == fixture.automation_provider
    assert submitted.model == "automation-model"
    assert_receive {:automation_wire, false, request, handler}, 5_000

    expected =
      "Recent conversation:\n- User: Source seed\n- Assistant: Source reply\n\n" <> authored

    assert user_texts(request) == [expected]
    assert request["model"] == "automation-model"

    assert {:ok, _} =
             Routines.update({"routine", config["id"]}, %{
               "automation_origin" => origin(fixture, other),
               "session_target" => "isolated",
               "delivery" => %{"mode" => "none"},
               "prompt" => "Replacement prompt"
             })

    send(handler, :continue_automation_execution)
    completed = completed(submitted, fixture)
    assert completed.metadata["automation_origin"] == origin(fixture, source)
    assert completed.metadata["session_target"] == "current"
    assert completed.metadata["delivery"] == %{"mode" => "announce"}
    assert completed.metadata["automation_context"]["status"] == "available"
    assert completed.metadata["automation_context"]["source_session_id"] == source.id
    assert completed.session_id not in [source.id, other.id]

    assert {:ok, delivered} =
             wait_for(fn ->
               if @result in assistant_texts(source.id), do: {:ok, :delivered}, else: :retry
             end)

    assert delivered == :delivered
    assert assistant_texts(source.id) == ["Source reply", @result]
    assert Sessions.get_messages(other.id) == []
    assert delivery(completed)["status"] == "delivered"
    assert delivery(completed)["source_session_id"] == source.id
    assert requests(fixture, "source-model") |> length() == 1
    assert {:ok, turns} = Store.list_turns(source.id)
    assert List.last(turns).parts == [%{type: "text", text: @result}]

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, source.id)
    assert :ok = DynamicSupervisor.stop_session(source.id)
    assert :ok = Sessions.ensure_running(source.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, source.id)
    assert old_worker != new_worker
    assert :ok = Worker.send_message(source.id, "Recall after automation")
    assert_receive {:source_wire, replay, _handler}, 5_000
    assert {"assistant", @result} in wire_texts(replay)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert Enum.count(assistant_texts(source.id), &(&1 == @result)) == 1
    assert File.read!(Path.join(ctx.tmp_dir, "automation-delivery-effect.txt")) == "effect"
  end

  test "isolated execution omits source context and none suppresses source delivery", ctx do
    fixture = fixture(ctx.tmp_dir)
    source = source(fixture)
    seed_source(source)
    authored = "Isolated authored prompt\nunchanged  "
    config = config(fixture, source, "isolated", "none", %{"prompt" => authored})
    assert {:ok, run} = Routines.trigger({"routine", config["id"]})
    assert_receive {:automation_wire, false, request, _handler}, 5_000
    assert user_texts(request) == [authored]
    completed = completed(run, fixture)
    assert completed.session_id != source.id
    assert completed.metadata["automation_context"]["status"] == "omitted"
    assert delivery(completed)["status"] == "suppressed"
    assert assistant_texts(source.id) == ["Source reply"]
    assert length(requests(fixture, "source-model")) == 1
  end

  test "a real heartbeat-kind at timer uses an empty exact source and announces after retirement",
       ctx do
    fixture = fixture(ctx.tmp_dir)
    source = source(fixture)
    assert {:ok, %{context: nil}} = Sessions.automation_context(source.id)

    target =
      DateTime.utc_now() |> DateTime.add(2_000, :millisecond) |> DateTime.truncate(:millisecond)

    config =
      config(fixture, source, "current", "announce", %{
        "kind" => "heartbeat",
        "schedule" => %{"kind" => "at", "at" => DateTime.to_iso8601(target)}
      })

    assert :ok = LocalScheduler.reload()

    assert {:ok, run} =
             wait_for(
               fn ->
                 case Enum.find(Runs.list_recent(limit: 100), &(&1.routine_id == config["id"])) do
                   nil -> :retry
                   run -> {:ok, run}
                 end
               end,
               10_000
             )

    completed = completed(run, fixture)
    assert completed.kind == "heartbeat"
    assert DateTime.compare(completed.scheduled_for, target) == :eq
    assert completed.metadata["automation_origin"] == origin(fixture, source)

    assert completed.metadata["automation_context"]["status"] == "empty",
           "context: #{inspect(completed.metadata["automation_context"])}; source: #{inspect(Sessions.automation_context(source.id))}"

    assert completed.provider == fixture.automation_provider
    assert completed.model == "automation-model"

    assert {:ok, :retired} =
             wait_for(fn ->
               if Enum.all?(ConfigStore.list(:routine), &(&1["id"] != config["id"])),
                 do: {:ok, :retired},
                 else: :retry
             end)

    assert delivery(completed)["status"] == "delivered"
    assert assistant_texts(source.id) == [@result]
    assert requests(fixture, "source-model") == []
    assert {:ok, ^completed} = Runs.fetch(run.id)
  end

  test "active source context stays detached and completed announce defers before the next queued prompt",
       ctx do
    fixture = fixture(ctx.tmp_dir, stream_source: true)
    source = source(fixture)
    assert :ok = Worker.send_message(source.id, "Source active prompt")
    assert_receive {:source_streaming, handler}, 5_000
    assert_receive {"text_delta", %{text: "Source live fragment"}}, 5_000
    [{source_worker, _}] = Registry.lookup(Synapsis.Session.Registry, source.id)
    {_, data} = :sys.get_state(source_worker)
    pointer = SessionAdapter.automation_snapshot(data.runtime_pid, 5_000)
    before = Backplane.AgentRuntime.Conversation.status(pointer.root).messages
    config = config(fixture, source, "current", "announce")
    assert {:ok, run} = Routines.trigger({"routine", config["id"]})
    assert_receive {:automation_wire, false, request, _handler}, 5_000
    [prompt] = user_texts(request)

    assert String.starts_with?(
             prompt,
             "Recent conversation:\n- User: Source active prompt\n- Assistant: Source live fragment\n\n"
           )

    completed = completed(run, fixture)
    assert completed.session_id != source.id
    assert delivery(completed)["status"] == "deferred"
    assert Backplane.AgentRuntime.Conversation.status(pointer.root).messages == before
    assert assistant_texts(source.id) == []
    assert :ok = Worker.send_message(source.id, "Queued source followup")
    send(handler, :continue_source_execution)
    assert_receive {:source_wire, following, _handler}, 5_000
    texts = wire_texts(following)

    assert Enum.find_index(texts, &(&1 == {"assistant", @result})) <
             Enum.find_index(texts, &(&1 == {"user", "Queued source followup"}))

    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert {:ok, :flushed} =
             wait_for(fn ->
               if @result in assistant_texts(source.id), do: {:ok, :flushed}, else: :retry
             end)

    assert Enum.count(assistant_texts(source.id), &(&1 == @result)) == 1
    assert length(requests(fixture, "source-model")) == 2
  end

  defp origin(fixture, source), do: %{"agent_id" => fixture.agent.id, "session_id" => source.id}

  defp config(fixture, source, target, mode, extra \\ %{}) do
    assert {:ok, saved} =
             ConfigStore.put(
               :routine,
               Map.merge(
                 %{
                   "id" => Ecto.UUID.generate(),
                   "name" => "Native automation delivery",
                   "kind" => "schedule",
                   "enabled" => true,
                   "schedule" => %{
                     "kind" => "every",
                     "everyMs" => 600_000,
                     "anchorMs" => System.system_time(:millisecond) + 600_000
                   },
                   "agent_name" => fixture.agent.name,
                   "tool_profile" => "native_agent",
                   "provider" => fixture.automation_provider,
                   "model" => "automation-model",
                   "prompt" => "Perform the automation effect",
                   "max_runtime_ms" => 30_000,
                   "automation_contract_version" => 1,
                   "automation_origin" => origin(fixture, source),
                   "session_target" => target,
                   "wake_mode" => "now",
                   "delivery" => %{"mode" => mode},
                   "metadata" => %{
                     "retained" => %{"trace" => "original"},
                     "automation_origin" => %{"session_id" => "untrusted metadata"}
                   }
                 },
                 extra
               )
             )

    saved
  end

  defp completed(run, fixture) do
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.summary == @result
    assert completed.tool_profile == "native_agent"
    assert completed.capability_snapshot["agent_id"] == fixture.agent.id
    assert completed.capability_snapshot["tool_names"] == ["exec_command"]

    assert [%ToolResult{is_error: false} = result] =
             for(
               message <- Sessions.get_messages(completed.session_id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    assert_receive {:automation_wire, true, following, _handler}, 5_000

    assert %{"role" => "tool", "tool_call_id" => result.tool_use_id, "content" => result.content} in following[
             "messages"
           ]

    assert {:ok, turns} = Store.list_turns(completed.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    completed
  end

  defp delivery(run) do
    assert {:ok, event} =
             wait_for(fn ->
               case Synapsis.AgentEvents.list(work_id: run.id, event_type: "automation.delivery") do
                 [event] -> {:ok, event}
                 _ -> :retry
               end
             end)

    event.payload
  end

  defp seed_source(source) do
    assert :ok = Worker.send_message(source.id, "Source seed")
    assert_receive {:source_wire, _request, _handler}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
  end

  defp source(fixture) do
    assert {:ok, session} =
             Sessions.create(fixture.agent.name, %{
               agent: fixture.agent.name,
               config: %{
                 "workspace_path" => fixture.root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
    on_exit(fn -> Sessions.delete(session.id) end)
    session
  end

  defp assistant_texts(id),
    do:
      for(
        %{role: "assistant", parts: parts} <- Sessions.get_messages(id),
        %Text{content: text} <- parts,
        do: text
      )

  defp user_texts(request), do: for({"user", text} <- wire_texts(request), do: text)

  defp wire_texts(request),
    do: Enum.map(request["messages"], &{&1["role"], content(&1["content"])})

  defp content(text) when is_binary(text), do: text

  defp content(blocks) when is_list(blocks),
    do: Enum.map_join(blocks, "", &Map.get(&1, "text", ""))

  defp content(_), do: ""

  defp requests(fixture, model),
    do: Agent.get(fixture.log, &Enum.filter(&1, fn request -> request["model"] == model end))

  defp fixture(root, opts \\ []) do
    http = Gaoxy.Test.open()
    provider = "automation-execution-#{Ecto.UUID.generate()}"
    override = provider <> "-override"
    owner = self()
    log = start_supervised!({Agent, fn -> [] end})

    for name <- [provider, override] do
      assert :ok =
               Synapsis.Provider.Registry.register(name, %{
                 type: "openai",
                 api_key: "test-key",
                 base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
               })
    end

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "source-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(log, &(&1 ++ [request]))
      target? = request["model"] == "automation-model"
      following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))

      cond do
        target? ->
          send(owner, {:automation_wire, following?, request, self()})

          if not following? and opts[:hold_automation] do
            receive do
              :continue_automation_execution -> :ok
            after
              15_000 -> raise "automation fixture was not released"
            end
          end

          chunks =
            if following? do
              [
                DeterministicProvider.text_chunk(@result),
                DeterministicProvider.finish_chunk("stop")
              ]
            else
              [
                DeterministicProvider.tool_call_chunk("exec_command", "automation-effect", %{
                  "cmd" => "printf effect >> automation-delivery-effect.txt",
                  "login" => false,
                  "yield_time_ms" => 1000
                }),
                DeterministicProvider.finish_chunk("tool_calls")
              ]
            end

          DeterministicProvider.send_sse(conn, chunks)

        opts[:stream_source] == true and List.last(user_texts(request)) == "Source active prompt" ->
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} =
            Plug.Conn.chunk(
              conn,
              "data: #{Jason.encode!(DeterministicProvider.text_chunk("Source live fragment"))}\n\n"
            )

          send(owner, {:source_streaming, self()})

          receive do
            :continue_source_execution -> :ok
          after
            15_000 -> raise "source fixture was not released"
          end

          DeterministicProvider.send_sse(conn, [DeterministicProvider.finish_chunk("stop")])

        true ->
          send(owner, {:source_wire, request, self()})

          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk("Source reply"),
            DeterministicProvider.finish_chunk("stop")
          ])
      end
    end)

    on_exit(fn ->
      for config <- ConfigStore.list(:routine),
          config["agent_name"] == agent.name,
          do: ConfigStore.delete(:routine, config["id"])

      LocalScheduler.reload()

      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == agent.name,
          is_binary(run.session_id),
          do: Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(agent)
      for name <- [provider, override], do: Synapsis.Provider.Registry.unregister(name)
    end)

    %{agent: agent, root: root, log: log, automation_provider: override}
  end
end
