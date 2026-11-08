defmodule Synapsis.Agent.ManagedAutomationLifecycleFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false

  alias Synapsis.Agent.{Routines, RunEvents}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.Text
  alias Synapsis.Session.Store
  alias Synapsis.Sessions

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    snapshots =
      for type <- [:routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        table = String.to_existing_atom("synapsis_config_#{type}")
        {type, pid, table, :ets.tab2list(table), :sys.get_state(pid).load_error}
      end

    System.put_env("SYNAPSIS_CONFIG_DIR", root)

    for {type, _, _, _, _} <- snapshots do
      File.write!(ConfigStore.file_path(type), "")
      assert :ok = ConfigStore.reload(type)
    end

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      for {_, pid, table, entries, error} <- snapshots do
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        :sys.replace_state(pid, &Map.put(&1, :load_error, error))
      end

      LocalScheduler.reload()
    end)

    :ok
  end

  for operation <- [:remove, :disable] do
    test "managed #{operation} commits configuration then requests exact-source lifecycle cancellation",
         ctx do
      managed_lifecycle(unquote(operation), ctx)
    end
  end

  test "compatible delete retains a submitted Run which can finish normally", %{tmp_dir: root} do
    fixture = fixture(root)
    target = {"routine", fixture.id}
    assert {:ok, active} = Routines.trigger(target, scheduler: fixture.scheduler)
    assert_receive {:managed_wire, "Managed active", handler}, 5_000
    assert {:ok, _} = wait_for_run(active.id, "running")
    assert {:ok, _} = Routines.delete(target, scheduler: fixture.scheduler)
    assert {:error, :not_found} = ConfigStore.get(:routine, fixture.id)
    assert Runs.get(active.id).status == "running"
    send(handler, :finish_managed_run)
    assert {:ok, completed} = wait_for_run(active.id, "completed")
    assert completed.summary == "Management continues"
    assert List.last(RunEvents.list_for_run(active.id))["type"] == "run.completed"
  end

  test "a new explicit force after disable runs independently and repeated disable is unchanged",
       %{
         tmp_dir: root
       } do
    fixture = fixture(root)
    target = {"routine", fixture.id}
    assert {:ok, disabled} = Routines.disable_automation(target, scheduler: fixture.scheduler)
    assert disabled.changed
    assert disabled.cancellation.status == :cancellation_requested

    assert {:ok, %{enqueued: true, run: run}} =
             Routines.run(target, :force, scheduler: fixture.scheduler)

    assert_receive {:managed_wire, "Managed active", handler}, 5_000
    assert {:ok, _} = wait_for_run(run.id, "running")
    assert {:ok, unchanged} = Routines.disable_automation(target, scheduler: fixture.scheduler)
    assert unchanged.changed == false
    assert unchanged.cancellation.status == :not_requested
    assert Runs.get(run.id).status == "running"
    send(handler, :finish_managed_run)
    assert {:ok, _} = wait_for_run(run.id, "completed")
    assert {:ok, saved} = ConfigStore.get(:routine, fixture.id)
    assert saved["enabled"] == false
    assert :sys.get_state(fixture.scheduler).timers[target] == nil
  end

  defp managed_lifecycle(operation, %{tmp_dir: root}) do
    fixture = fixture(root)
    target = {"routine", fixture.id}
    sibling_target = {"heartbeat", fixture.id}
    assert {:ok, active} = Routines.trigger(target, scheduler: fixture.scheduler)
    assert_receive {:managed_wire, "Managed active", handler}, 5_000
    assert {:ok, _} = wait_for_run(active.id, "running")
    assert {:ok, queued} = Routines.trigger(target, scheduler: fixture.scheduler)
    assert {:ok, sibling} = Routines.trigger(sibling_target, scheduler: fixture.scheduler)

    result =
      case operation do
        :remove -> Routines.remove_automation(target, scheduler: fixture.scheduler)
        :disable -> Routines.disable_automation(target, scheduler: fixture.scheduler)
      end

    assert {:ok, receipt} = result

    assert receipt.source == "routine"
    assert receipt.id == fixture.id
    assert receipt.persisted
    assert receipt.cancellation.status == :cancellation_requested
    assert receipt.cancellation.cleanup_pending
    assert receipt.cancellation.active_count == 1
    assert receipt.cancellation.queued_count == 1

    case operation do
      :remove ->
        assert receipt.removed
        assert {:error, :not_found} = ConfigStore.get(:routine, fixture.id)

      :disable ->
        assert receipt.routine["enabled"] == false
        assert receipt.routine["automation_origin"] == fixture.origin
        assert {:ok, saved} = ConfigStore.get(:routine, fixture.id)
        assert saved["enabled"] == false
        assert :ok = ConfigStore.reload(:routine)
        assert {:ok, reloaded} = ConfigStore.get(:routine, fixture.id)
        assert reloaded["enabled"] == false
        assert reloaded["automation_origin"] == fixture.origin
    end

    assert :sys.get_state(fixture.scheduler).timers[target] == nil
    assert :sys.get_state(fixture.scheduler).timers[sibling_target] != nil
    assert {:ok, sibling_config} = ConfigStore.get(:heartbeat, fixture.id)
    assert sibling_config["enabled"]

    for run <- [active, queued] do
      assert {:ok, cancelled} = wait_for_run(run.id, "cancelled")

      assert cancelled.metadata["automation_ref"] == %{
               "source" => "routine",
               "id" => fixture.id
             }

      assert List.last(RunEvents.list_for_run(run.id))["type"] == "run.cancelled"
    end

    assert_receive {:provider_disconnected, ^handler}, 5_000
    assert_receive {:managed_wire, "Sibling continues", _}, 5_000
    assert {:ok, completed} = wait_for_run(sibling.id, "completed")
    assert completed.summary == "Management continues"

    assert {:ok, source} =
             Sessions.create(fixture.agent, %{
               agent: fixture.agent,
               config: %{
                 "workspace_path" => root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    on_exit(fn -> Sessions.delete(source.id) end)
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{source.id}")
    assert :ok = Sessions.send_message(source.id, "Independent management caller")
    assert_receive {:managed_wire, "Independent management caller", _}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 5_000
    assert {:ok, turns} = Store.list_turns(source.id)

    assert Enum.any?(
             turns,
             &(&1.role == "assistant" and
                 &1.parts == [%{type: "text", text: "Management continues"}])
           )

    assert Enum.any?(Sessions.get_messages(source.id), fn message ->
             Enum.any?(message.parts, &match?(%Text{content: "Management continues"}, &1))
           end)

    assert Agent.get(
             fixture.requests,
             &Enum.count(&1, fn prompt -> prompt == "Managed active" end)
           ) == 1
  end

  defp fixture(root) do
    http = Gaoxy.Test.open()
    owner = self()
    requests = start_supervised!({Agent, fn -> [] end})

    Gaoxy.Test.expect(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      prompt =
        request["messages"]
        |> Enum.filter(&(&1["role"] == "user"))
        |> List.last()
        |> Map.fetch!("content")
        |> text()

      Agent.update(requests, &[prompt | &1])
      send(owner, {:managed_wire, prompt, self()})

      outcome =
        if prompt == "Managed active" do
          Synapsis.Agent.TestSupport.AbortableHTTP.await(conn, :finish_managed_run, 10_000, owner)
        else
          {:released, conn}
        end

      case outcome do
        {:released, conn} ->
          send_sse(conn, [text_chunk("Management continues"), finish_chunk("stop")])

        {:disconnected, conn} ->
          conn

        {:timeout, _} ->
          raise "managed fixture was not completed"
      end
    end)

    {provider, agent} = register_provider_agent(root, http)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(Synapsis.AgentConfigs.get_by_name(agent), %{
               tool_contract_version: 1,
               tools: ["exec_command"]
             })

    {daemon, supervisor} = start_test_daemon()

    scheduler =
      String.to_atom("managed_automation_scheduler_#{System.unique_integer([:positive])}")

    start_supervised!(
      {LocalScheduler,
       name: scheduler, daemon: daemon, task_supervisor: supervisor, reload_interval_ms: 60_000}
    )

    id = Ecto.UUID.generate()
    origin = %{"agent_id" => Ecto.UUID.generate(), "session_id" => Ecto.UUID.generate()}

    base = %{
      "id" => id,
      "agent_name" => agent,
      "provider" => provider,
      "model" => "daemon-test-model",
      "enabled" => true,
      "no_overlap" => false,
      "tool_profile" => "native_agent"
    }

    assert {:ok, _} =
             ConfigStore.put(
               :routine,
               Map.merge(base, %{
                 "name" => "Managed",
                 "prompt" => "Managed active",
                 "kind" => "schedule",
                 "automation_contract_version" => 1,
                 "automation_origin" => origin,
                 "session_target" => "isolated",
                 "delivery" => %{"mode" => "none"},
                 "schedule" => %{"kind" => "every", "everyMs" => 3_600_000}
               })
             )

    assert {:ok, _} =
             ConfigStore.put(
               :heartbeat,
               Map.merge(base, %{
                 "name" => "Sibling",
                 "prompt" => "Sibling continues",
                 "schedule" => "0 0 1 1 *"
               })
             )

    assert :ok = LocalScheduler.reload(scheduler)
    %{id: id, origin: origin, agent: agent, scheduler: scheduler, requests: requests}
  end

  defp text(value) when is_binary(value), do: value
  defp text(values), do: Enum.map_join(values, "", &Map.get(&1, "text", ""))
end
