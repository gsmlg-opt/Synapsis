defmodule Synapsis.Agent.Tools.AutomationManagementFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Backplane.AgentRuntime.InputSchema
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.Routines
  alias Synapsis.Agent.Tools.{AutomationManagement, Automations, DisplayCatalog, Profiles}
  alias Synapsis.AgentRun
  alias Synapsis.Config.Store

  @moduletag :tmp_dir
  @name "synapsis::automations_manage"

  setup %{tmp_dir: root} do
    original =
      for type <- [:agent, :routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        {type, :sys.get_state(pid).load_error, :ets.tab2list(:"synapsis_config_#{type}")}
      end

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    directory = Path.join(root, "config")
    File.mkdir_p!(directory)
    System.put_env("SYNAPSIS_CONFIG_DIR", directory)

    for type <- [:agent, :routine, :heartbeat] do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      for {type, load_error, entries} <- original do
        table = :"synapsis_config_#{type}"
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        :sys.replace_state(pid, &Map.put(&1, :load_error, load_error))
      end

      LocalScheduler.reload()
    end)

    %{
      context: %{
        session_id: Ecto.UUID.generate(),
        requester_name: "main",
        run_id: "/root/automation-management",
        incarnation: 1,
        catalog_revision: 1
      }
    }
  end

  test "separate revision-one run descriptor preserves the four-action read descriptor", ctx do
    assert {:ok, [reader]} = Automations.descriptors(ctx.context)
    assert reader.tool_revision == 2
    assert reader.schema["properties"]["action"]["enum"] == ~w(status list get runs)
    assert reader.safety == %{read_only: true, retry_safe: true, parallel_safe: true}

    assert {:ok, [descriptor]} = AutomationManagement.descriptors(ctx.context)
    assert AutomationManagement.names() == [@name]
    assert descriptor.tool_name == @name
    assert descriptor.tool_revision == 1
    assert descriptor.backend == AutomationManagement
    assert descriptor.backend_context == ctx.context
    assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert descriptor.schema["properties"]["action"]["enum"] == ["run"]
    assert descriptor.schema["properties"]["source"]["enum"] == ~w(routine heartbeat)
    assert descriptor.schema["properties"]["runMode"]["enum"] == ~w(due force)
    assert descriptor.schema["properties"]["runMode"]["default"] == "due"
    assert descriptor.schema["properties"]["timeoutMs"]["maximum"] == 60_000
    assert Enum.sort(descriptor.schema["required"]) == ~w(action id source)
    assert descriptor.schema["additionalProperties"] == false

    for source <- ~w(routine heartbeat), mode <- ~w(due force) do
      assert {:ok, _} =
               InputSchema.validate(descriptor.schema, %{
                 "action" => "run",
                 "source" => source,
                 "id" => Ecto.UUID.generate(),
                 "runMode" => mode,
                 "timeoutMs" => 1_000
               })
    end

    assert @name in Profiles.supported_names()
    assert Enum.any?(DisplayCatalog.list(), &(&1.name == @name))

    assert {:ok, [^reader]} = Automations.descriptors(ctx.context)
  end

  test "mode-bearing domain run defaults to a successful future or disabled due no-op" do
    target = future(60_000)
    routine = put_routine(at(target))
    disabled = put_routine(at(target), %{"enabled" => false})
    scheduler = scheduler([routine, disabled])

    assert {:ok, %{enqueued: false, reason: :not_due, run: nil}} =
             Routines.run({"routine", routine["id"]}, :due, scheduler: scheduler)

    assert {:ok, %{enqueued: false, reason: :disabled, run: nil}} =
             Routines.run({"routine", disabled["id"]}, :due, scheduler: scheduler)

    refute_received {:submitted, _, _}
    assert {:ok, ^routine} = Store.get(:routine, routine["id"])
    assert {:ok, ^disabled} = Store.get(:routine, disabled["id"])
  end

  test "force runs disabled future configurations while preserving their scheduled occurrence" do
    target = future(60_000)
    routine = put_routine(at(target), %{"enabled" => false})
    scheduler = scheduler([routine])

    assert {:ok, %{enqueued: true, run: %AgentRun{} = run}} =
             Routines.run({"routine", routine["id"]}, :force, scheduler: scheduler)

    assert_receive {:submitted, submitted, ^run}
    assert submitted["__schedule_context"]["advance"] == false
    assert submitted["__schedule_context"]["occurrence"] == DateTime.to_iso8601(target)
    assert submitted["__schedule_context"]["generation"] == routine["schedule_generation"]
    assert submitted["__idempotency_key"] =~ ":manual:"
    assert {:ok, ^routine} = Store.get(:routine, routine["id"])
    assert LocalScheduler.status(scheduler) == []
  end

  test "due request and real timer share one reserved source generation and occurrence" do
    owner = self()
    target = future(250)
    routine = put_routine(at(target), %{"deleteAfterRun" => false})

    scheduler =
      scheduler([routine], fn config, _daemon ->
        send(owner, {:held_submit, self(), config})

        receive do
          :complete_submission -> {:ok, %AgentRun{id: Ecto.UUID.generate(), status: "queued"}}
        after
          5_000 -> raise "ordinary submission handshake timed out"
        end
      end)

    assert_receive {:held_submit, submitter, submitted}, 5_000
    assert submitted["__schedule_context"]["advance"] == true
    expected = submitted["__idempotency_key"]
    assert expected =~ routine["schedule_generation"]
    assert expected =~ DateTime.to_iso8601(target)
    task = Task.async(fn -> LocalScheduler.run(scheduler, {"routine", routine["id"]}, :due) end)

    assert {:ok, %{running: true}} = LocalScheduler.public_status(server: scheduler)
    send(submitter, :complete_submission)
    assert {:ok, %{enqueued: true, run: %AgentRun{} = run}} = Task.await(task, 5_000)

    assert {:ok, _} =
             wait_for(fn ->
               if Map.has_key?(:sys.get_state(scheduler).tracked_runs, run.id),
                 do: {:ok, run},
                 else: :retry
             end)

    assert {:ok, %{enqueued: true, run: ^run}} =
             LocalScheduler.run(scheduler, {"routine", routine["id"]}, :due)

    refute_received {:held_submit, _, _}
  end

  test "same UUID routine and heartbeat remain separate force targets" do
    id = Ecto.UUID.generate()
    routine = put_routine(at(future(60_000)), %{"id" => id})

    heartbeat = %{
      "id" => id,
      "name" => "management-heartbeat-#{id}",
      "kind" => "heartbeat",
      "enabled" => false,
      "schedule" => "0 0 1 1 *",
      "__config_type" => "heartbeat"
    }

    scheduler = scheduler([routine, heartbeat])

    assert {:ok, %{run: first}} = LocalScheduler.run(scheduler, {"routine", id}, :force)
    assert_receive {:submitted, %{"__config_type" => "routine"}, ^first}
    assert {:ok, %{run: second}} = LocalScheduler.run(scheduler, {"heartbeat", id}, :force)
    assert_receive {:submitted, %{"__config_type" => "heartbeat"}, ^second}
    assert first.id != second.id
  end

  defp scheduler(configs, submit \\ nil) do
    owner = self()
    configs = Enum.map(configs, &Map.put_new(&1, "__config_type", "routine"))

    submit =
      submit ||
        fn config, _daemon ->
          run = %AgentRun{id: Ecto.UUID.generate(), status: "queued"}
          send(owner, {:submitted, config, run})
          {:ok, run}
        end

    server = String.to_atom("management_scheduler_#{System.unique_integer([:positive])}")

    start_supervised!(
      {LocalScheduler,
       name: server,
       config_loader: fn -> configs end,
       config_writer: fn _type, attrs -> {:ok, attrs} end,
       trigger_fun: submit,
       reload_interval_ms: 60_000}
    )

    assert :ok = LocalScheduler.reload(server)
    server
  end

  defp put_routine(schedule, extra \\ %{}) do
    assert {:ok, config} =
             Store.put(
               :routine,
               Map.merge(
                 %{
                   "id" => Ecto.UUID.generate(),
                   "name" => "management-#{Ecto.UUID.generate()}",
                   "kind" => "schedule",
                   "enabled" => true,
                   "schedule" => schedule,
                   "prompt" => "ordinary management fixture"
                 },
                 extra
               )
             )

    config
  end

  defp future(ms),
    do: DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.truncate(:millisecond)

  defp at(target), do: %{"kind" => "at", "at" => DateTime.to_iso8601(target)}
end
