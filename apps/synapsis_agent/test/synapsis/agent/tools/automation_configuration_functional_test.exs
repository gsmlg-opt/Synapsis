defmodule Synapsis.Agent.Tools.AutomationConfigurationFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.{Heartbeat.LocalScheduler, Routines}

  alias Synapsis.Agent.Tools.{
    AutomationConfiguration,
    AutomationManagement,
    Automations,
    DisplayCatalog,
    Profiles
  }

  alias Synapsis.Config.Store

  @moduletag :tmp_dir
  @name "synapsis::automations_create"

  setup %{tmp_dir: root} do
    [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, :routine)
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    entries = :ets.tab2list(:synapsis_config_routine)
    error = :sys.get_state(pid).load_error
    System.put_env("SYNAPSIS_CONFIG_DIR", root)
    File.write!(Store.file_path(:routine), "")
    assert :ok = Store.reload(:routine)

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      :ets.delete_all_objects(:synapsis_config_routine)
      :ets.insert(:synapsis_config_routine, entries)
      :sys.replace_state(pid, &Map.put(&1, :load_error, error))
      LocalScheduler.reload()
    end)

    %{
      context: %{
        session_id: Ecto.UUID.generate(),
        creator_agent_id: Ecto.UUID.generate(),
        requester_name: "main",
        run_id: "/root/configuration",
        incarnation: 1,
        catalog_revision: 1
      }
    }
  end

  test "explicit create descriptor preserves the existing read and run descriptors", ctx do
    original = Map.drop(ctx.context, [:creator_agent_id])
    assert {:ok, [reader]} = Automations.descriptors(original)
    assert {:ok, [runner]} = AutomationManagement.descriptors(original)
    assert {:ok, [create]} = AutomationConfiguration.descriptors(ctx.context)
    assert create.tool_name == @name
    assert create.tool_revision == 1
    assert create.backend_context == ctx.context
    assert create.safety == %{read_only: false, retry_safe: false, parallel_safe: false}

    assert {:ok, _} =
             Backplane.AgentRuntime.InputSchema.validate(create.schema, %{
               "prompt" => "Reminder",
               "schedule" => %{"kind" => "every", "everyMs" => 60_000}
             })

    assert @name in Profiles.supported_names()
    assert Enum.any?(DisplayCatalog.list(), &(&1.name == @name))
    assert {:ok, [^reader]} = Automations.descriptors(original)
    assert {:ok, [^runner]} = AutomationManagement.descriptors(original)
  end

  test "domain create acknowledges persisted identity and scheduler reload with trusted origin",
       ctx do
    attrs = %{
      "prompt" => "\n  Authored reminder  \n",
      "schedule" => %{"kind" => "every", "everyMs" => 600_000}
    }

    assert {:ok, receipt} = Routines.create_automation(attrs, ctx.context)
    assert receipt.persisted == true
    assert receipt.activation == "reloaded"
    assert receipt.source == "routine"

    assert {:ok, saved} =
             wait_for(fn ->
               case Store.get(:routine, receipt.id) do
                 {:ok, %{"next_run_at" => _} = saved} -> {:ok, saved}
                 _ -> :retry
               end
             end)

    assert saved["prompt"] == attrs["prompt"]
    assert saved["name"] == "Authored reminder"
    assert saved["tool_profile"] == "native_agent"

    assert saved["automation_origin"] == %{
             "agent_id" => ctx.context.creator_agent_id,
             "session_id" => ctx.context.session_id
           }

    assert saved["session_target"] == "current"
    assert saved["delivery"] == %{"mode" => "announce"}
    assert :ok = Store.reload(:routine)
    assert {:ok, ^saved} = Store.get(:routine, receipt.id)

    assert {:ok, renamed} =
             Routines.update({"routine", receipt.id}, %{
               "name" => "Renamed",
               "agent_name" => "different-route",
               "delivery" => %{"mode" => "none"}
             })

    assert renamed["automation_origin"] == saved["automation_origin"]
    assert renamed["schedule_generation"] == saved["schedule_generation"]
    assert renamed["agent_name"] == "different-route"
    assert renamed["delivery"] == %{"mode" => "none"}
  end

  test "disabled isolated creation retains explicit false and none while acknowledging configuration",
       ctx do
    assert {:ok, receipt} =
             Routines.create_automation(
               %{
                 "prompt" => "Keep for later",
                 "enabled" => false,
                 "session_target" => "isolated",
                 "delivery" => %{"mode" => "none"},
                 "deleteAfterRun" => false,
                 "schedule" => %{
                   "kind" => "at",
                   "at" =>
                     DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()
                 }
               },
               ctx.context
             )

    assert receipt.persisted == true
    assert receipt.activation == "reloaded"
    assert receipt.routine["enabled"] == false
    assert receipt.routine["deleteAfterRun"] == false
    assert receipt.routine["session_target"] == "isolated"
    assert receipt.routine["delivery"] == %{"mode" => "none"}
    assert :sys.get_state(LocalScheduler).timers[{"routine", receipt.id}] == nil
  end
end
