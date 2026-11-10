defmodule Synapsis.Agent.Heartbeat.AutomationIdentityFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.{Routines, RunEvents}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir

  test "source-qualified lifecycle keeps same UUID records and partial updates separate", ctx do
    {saved, _counter} = native_fixture(ctx.tmp_dir)
    id = Ecto.UUID.generate()
    stored_config(saved, :routine, id)
    stored_config(saved, :heartbeat, id)
    scheduler = start_scheduler()

    assert {:ok, {routine, heartbeat}} =
             wait_for(fn ->
               with {:ok, %{"next_run_at" => routine_at} = routine} <-
                      ConfigStore.get(:routine, id),
                    {:ok, %{"next_run_at" => heartbeat_at} = heartbeat} <-
                      ConfigStore.get(:heartbeat, id),
                    true <- is_binary(routine_at) and is_binary(heartbeat_at) do
                 {:ok, {routine, heartbeat}}
               else
                 _ -> :retry
               end
             end)

    assert {:ok, projected_routine} = Routines.get({"routine", id})
    assert {:ok, projected_heartbeat} = Routines.get({"heartbeat", id})
    assert projected_routine == Map.put(routine, "source", "routine")
    assert projected_heartbeat == Map.put(heartbeat, "source", "heartbeat")

    assert Enum.sort(Enum.map(Enum.filter(Routines.list(), &(&1["id"] == id)), & &1["source"])) ==
             ["heartbeat", "routine"]

    assert {:ok, updated} =
             Routines.update({"heartbeat", id}, %{"prompt" => "source heartbeat updated"},
               scheduler: scheduler
             )

    assert updated["source"] == "heartbeat"
    assert updated["id"] == id
    assert updated["prompt"] == "source heartbeat updated"
    assert Map.drop(updated, ["source", "prompt"]) == Map.delete(heartbeat, "prompt")
    assert {:ok, ^routine} = ConfigStore.get(:routine, id)
    assert {:ok, persisted} = ConfigStore.get(:heartbeat, id)
    assert persisted == Map.delete(updated, "source")

    assert {:ok, removed} = Routines.delete({"routine", id}, scheduler: scheduler)
    assert removed == projected_routine
    assert ConfigStore.list(:routine) |> Enum.all?(&(&1["id"] != id))
    assert {:ok, ^persisted} = ConfigStore.get(:heartbeat, id)
    assert {:ok, ^updated} = Routines.get(id)

    assert [%{id: ^id, source: "heartbeat"}] =
             Enum.filter(LocalScheduler.status(scheduler), &(&1.id == id))
  end

  test "same UUID native runs survive scheduler replacement and keep source-specific history",
       ctx do
    assert {:ok, _} = wait_for_ready()
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())
    {saved, counter} = native_fixture(ctx.tmp_dir)
    id = Ecto.UUID.generate()
    stored_config(saved, :routine, id)
    stored_config(saved, :heartbeat, id)
    assert {:ok, _} = ConfigStore.merge_existing(:routine, id, %{"source" => "heartbeat"})
    scheduler = start_scheduler()
    old_scheduler = Process.whereis(scheduler)

    assert Enum.sort(
             Enum.map(Enum.filter(LocalScheduler.status(scheduler), &(&1.id == id)), & &1.source)
           ) ==
             ["heartbeat", "routine"]

    initial_state = :sys.get_state(scheduler)
    assert is_reference(initial_state.timers[{"routine", id}].ref)
    assert is_reference(initial_state.timers[{"heartbeat", id}].ref)

    assert {:ok, routine_run} = Routines.trigger({"routine", id}, scheduler: scheduler)
    assert_receive {:identity_request, "routine", false, handler, first}, 5_000
    assert first["tools"] |> Enum.map(& &1["function"]["name"]) == ["exec_command"]

    assert {:ok, heartbeat_run} = Routines.trigger({"heartbeat", id}, scheduler: scheduler)
    assert heartbeat_run.id != routine_run.id
    assert heartbeat_run.status == "queued"

    for {source, run_id} <- [{"routine", routine_run.id}, {"heartbeat", heartbeat_run.id}] do
      assert_receive {:agent_daemon_event,
                      %{
                        event: "agent.routine.triggered",
                        source: ^source,
                        routine_id: ^id,
                        run_id: ^run_id
                      }},
                     5_000
    end

    assert {:ok, status} =
             wait_for_status(Daemon, &(&1.active_count == 1 and &1.queued_count == 1))

    assert status.ready

    monitor = Process.monitor(old_scheduler)
    assert :ok = stop_supervised(LocalScheduler)
    assert_receive {:DOWN, ^monitor, :process, ^old_scheduler, _reason}, 5_000
    assert ^scheduler = start_scheduler(scheduler)
    assert Process.whereis(scheduler) != old_scheduler
    assert :sys.get_state(scheduler).tracked_runs == %{}

    send(handler, :continue_identity)
    completed_routine = assert_native_run(routine_run, saved, "routine", ctx.tmp_dir)
    completed_heartbeat = assert_native_run(heartbeat_run, saved, "heartbeat", ctx.tmp_dir)
    assert Agent.get(counter, & &1) == 4

    for {source, run} <- [{"routine", completed_routine}, {"heartbeat", completed_heartbeat}] do
      ref = %{"source" => source, "id" => id}
      run_id = run.id
      type = if source == "routine", do: :routine, else: :heartbeat

      assert run.kind == "heartbeat"
      assert run.routine_id == id
      assert run.metadata["automation_ref"] == ref

      assert_receive {:agent_daemon_event,
                      %{
                        event: "agent.run.completed",
                        run_id: ^run_id,
                        payload: %{automation_ref: ^ref}
                      }},
                     5_000

      assert_receive {:identity_persist, ^type, %{"id" => ^id, "last_status" => "completed"}},
                     5_000

      assert {:ok, persisted} =
               wait_for(fn ->
                 case ConfigStore.get(type, id) do
                   {:ok, %{"last_status" => "completed", "last_run_at" => at} = config}
                   when is_binary(at) ->
                     {:ok, config}

                   _ ->
                     :retry
                 end
               end)

      assert persisted["custom_marker"] == source
      assert persisted["prompt"] == "source #{source}"
      assert is_binary(persisted["next_run_at"])
      assert persisted["id"] == id
      assert {:ok, page} = Synapsis.RoutineRuns.page(saved.name, source, id)
      assert [%{id: ^run_id, status: "completed", automation_ref: ^ref}] = page.runs

      assert Enum.map(RunEvents.list_for_run(run_id), & &1["type"]) ==
               ["run.created", "run.starting", "run.started", "run.completed"]
    end

    assert {:ok, _} =
             wait_for(fn ->
               entries = Enum.filter(LocalScheduler.status(scheduler), &(&1.id == id))

               if length(entries) == 2 and
                    Enum.all?(entries, &(Map.get(&1, :last_status) == "completed")),
                  do: {:ok, entries},
                  else: :retry
             end)

    routine_timer = :sys.get_state(scheduler).timers[{"routine", id}].ref
    assert {:ok, removed} = Routines.delete({"routine", id}, scheduler: scheduler)
    assert removed["source"] == "routine"
    assert Process.read_timer(routine_timer) == false

    assert [%{id: ^id, source: "heartbeat", last_status: "completed"}] =
             Enum.filter(LocalScheduler.status(scheduler), &(&1.id == id))

    assert ConfigStore.list(:routine) |> Enum.all?(&(&1["id"] != id))
    assert {:ok, ^completed_routine} = Runs.fetch(completed_routine.id)
    assert {:ok, ^completed_heartbeat} = Runs.fetch(completed_heartbeat.id)

    assert Enum.map(RunEvents.list_for_run(completed_routine.id), & &1["type"]) ==
             ["run.created", "run.starting", "run.started", "run.completed"]

    assert_worker_replay(completed_routine, ctx.tmp_dir)
    assert Agent.get(counter, & &1) == 5
    assert File.read!(Path.join(ctx.tmp_dir, "identity-heartbeat.txt")) == "effect"
    assert {:ok, ^completed_routine} = Runs.fetch(completed_routine.id)
  end

  defp start_scheduler(name \\ nil) do
    owner = self()
    name = name || String.to_atom("identity_scheduler_#{System.unique_integer([:positive])}")

    start_supervised!(
      {LocalScheduler,
       name: name,
       reload_interval_ms: 60_000,
       config_writer: fn type, attrs ->
         result = ConfigStore.merge_existing(type, attrs["id"], Map.delete(attrs, "id"))
         send(owner, {:identity_persist, type, attrs})
         result
       end}
    )

    assert :ok = LocalScheduler.reload(name)
    name
  end

  defp stored_config(saved, type, id) do
    source = Atom.to_string(type)

    assert {:ok, config} =
             ConfigStore.put(type, %{
               "id" => id,
               "name" => "identity-#{source}-#{id}",
               "kind" => "heartbeat",
               "enabled" => true,
               "schedule" => "0 0 1 1 *",
               "agent_name" => saved.name,
               "tool_profile" => "native_agent",
               "prompt" => "source #{source}",
               "custom_marker" => source,
               "no_overlap" => true,
               "max_runtime_ms" => 30_000
             })

    on_exit(fn ->
      ConfigStore.delete(type, id)
      LocalScheduler.reload()
    end)

    config
  end

  defp native_fixture(root) do
    fixture = Gaoxy.Test.open()
    provider = "identity-producer-#{Ecto.UUID.generate()}"
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "identity-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      source =
        if String.contains?(Jason.encode!(request["messages"]), "source heartbeat"),
          do: "heartbeat",
          else: "routine"

      following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))
      Agent.update(counter, &(&1 + 1))
      send(owner, {:identity_request, source, following?, self(), request})

      if source == "routine" and not following? do
        receive do
          :continue_identity -> :ok
        after
          20_000 -> raise "identity fixture handshake timed out"
        end
      end

      chunks =
        if following? do
          [
            DeterministicProvider.text_chunk("#{source} complete"),
            DeterministicProvider.finish_chunk("stop")
          ]
        else
          [
            DeterministicProvider.tool_call_chunk("exec_command", "identity-#{source}", %{
              "cmd" => "printf effect >> identity-#{source}.txt",
              "login" => false,
              "yield_time_ms" => 1000
            }),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    {saved, counter}
  end

  defp assert_native_run(run, saved, source, root) do
    assert run.tool_profile == "native_agent"
    assert run.assistant_name == saved.name
    assert run.capability_snapshot["agent_id"] == saved.id
    assert run.capability_snapshot["tool_names"] == ["exec_command"]
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert_receive {:identity_request, ^source, true, _handler, following}, 5_000
    assert File.read!(Path.join(root, "identity-#{source}.txt")) == "effect"

    assert [%ToolResult{is_error: false} = result] =
             for(
               message <- Synapsis.Sessions.get_messages(completed.session_id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    assert %{"role" => "tool", "tool_call_id" => result.tool_use_id, "content" => result.content} in following[
             "messages"
           ]

    assert {:ok, turns} = Store.list_turns(completed.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert {:ok, ^completed} = Runs.fetch(completed.id)
    completed
  end

  defp assert_worker_replay(run, root) do
    session_id = run.session_id
    SessionHarness.subscribe!(session_id)
    SessionHarness.ensure_running!(session_id)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)

    parts =
      for message <- Synapsis.Sessions.get_messages(session_id),
          %ToolResult{} = part <- message.parts,
          do: part

    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(session_id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    SessionHarness.ensure_running!(session_id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
    assert new_worker != old_worker
    assert :ok = Worker.send_message(session_id, "Recall source routine completion")
    assert_receive {:identity_request, "routine", true, _handler, replay}, 5_000

    for part <- parts do
      assert %{"role" => "tool", "tool_call_id" => part.tool_use_id, "content" => part.content} in replay[
               "messages"
             ]
    end

    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert for(
             message <- Synapsis.Sessions.get_messages(session_id),
             %ToolResult{} = part <- message.parts,
             do: part
           ) == parts

    assert File.read!(Path.join(root, "identity-routine.txt")) == "effect"
    assert :ok = DynamicSupervisor.stop_session(session_id)
  end
end
