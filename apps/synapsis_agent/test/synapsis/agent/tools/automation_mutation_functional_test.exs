defmodule Synapsis.Agent.Tools.AutomationMutationFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for_ready: 0]

  alias Backplane.AgentRuntime.InputSchema
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.Routines

  alias Synapsis.Agent.Tools.{
    AutomationConfiguration,
    AutomationManagement,
    AutomationMutation,
    Automations,
    DisplayCatalog,
    Profiles
  }

  alias Synapsis.Config.Store
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @update "synapsis::automations_update"
  @remove "synapsis::automations_remove"

  setup %{tmp_dir: root} do
    assert {:ok, _} = wait_for_ready()

    original =
      for type <- [:routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        {type, :sys.get_state(pid).load_error, :ets.tab2list(:"synapsis_config_#{type}")}
      end

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    System.put_env("SYNAPSIS_CONFIG_DIR", root)

    for type <- [:routine, :heartbeat] do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

    assert :ok = LocalScheduler.reload()

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
        creator_agent_id: Ecto.UUID.generate(),
        requester_name: "main",
        run_id: "/root/automation-mutation",
        incarnation: 1,
        catalog_revision: 1
      }
    }
  end

  test "separate update and remove descriptors preserve the existing create read and run contracts",
       ctx do
    reader_context = Map.drop(ctx.context, [:creator_agent_id])
    assert {:ok, [reader]} = Automations.descriptors(reader_context)
    assert {:ok, [runner]} = AutomationManagement.descriptors(reader_context)
    assert {:ok, [creator]} = AutomationConfiguration.descriptors(ctx.context)
    assert {:ok, [update, remove]} = AutomationMutation.descriptors(ctx.context)
    assert AutomationMutation.names() == [@update, @remove]
    assert AutomationMutation.revision() == 1

    assert :ok =
             SessionStore.put_value(
               ctx.context.session_id,
               "permission",
               %Synapsis.SessionPermission{
                 session_id: ctx.context.session_id,
                 tool_contract_version: 1
               }
             )

    on_exit(fn -> SessionStore.delete_session(ctx.context.session_id) end)

    for descriptor <- [update, remove] do
      assert descriptor.tool_revision == 1
      assert descriptor.backend == AutomationMutation
      assert descriptor.backend_context == ctx.context
      assert descriptor.tool_name in Profiles.supported_names()
      assert Enum.any?(DisplayCatalog.list(), &(&1.name == descriptor.tool_name))

      identity =
        Map.put(
          Map.take(ctx.context, [:session_id, :run_id, :incarnation, :catalog_revision]),
          :caller,
          "automation-mutation-test"
        )

      profile_context = %{
        session: %{id: ctx.context.session_id, config: %{"subagents" => false}},
        agent: %{
          id: ctx.context.creator_agent_id,
          name: ctx.context.requester_name,
          tools: [descriptor.tool_name],
          tool_contract_version: 1
        }
      }

      ceiling = %{
        caller: identity.caller,
        run_id: identity.run_id,
        grants: [descriptor.tool_name],
        tool_revisions: %{descriptor.tool_name => 1}
      }

      assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
               Profiles.build(profile_context, identity, [], ceiling)

      assert Map.keys(bundle.registry.tools) == [descriptor.tool_name]
      assert bundle.registry.tools[descriptor.tool_name].backend_context == ctx.context
      assert Map.keys(snapshot.selected) == [descriptor.tool_name]
    end

    assert update.tool_name == @update
    assert remove.tool_name == @remove
    assert Enum.sort(update.schema["required"]) == ~w(id patch source)
    assert Enum.sort(remove.schema["required"]) == ~w(id source)

    for patch <- [
          %{
            "schedule" => %{
              "kind" => "cron",
              "expr" => "0 * * * *",
              "tz" => nil,
              "staggerMs" => 0
            },
            "provider" => nil,
            "model" => nil,
            "enabled" => false,
            "delivery" => %{"mode" => "none"}
          },
          %{"name" => "Legacy reminder", "schedule" => "*/5 * * * *"}
        ] do
      assert {:ok, _} =
               InputSchema.validate(update.schema, %{
                 "source" => "routine",
                 "id" => Ecto.UUID.generate(),
                 "patch" => patch
               })
    end

    assert {:ok, _} =
             InputSchema.validate(remove.schema, %{
               "source" => "heartbeat",
               "id" => Ecto.UUID.generate()
             })

    assert {:ok, [^reader]} = Automations.descriptors(reader_context)
    assert {:ok, [^runner]} = AutomationManagement.descriptors(reader_context)
    assert {:ok, [^creator]} = AutomationConfiguration.descriptors(ctx.context)
  end

  test "native update from a later creator session retains the original source and encoded receipt",
       ctx do
    receipt = create(ctx.context)
    id = receipt.id
    later = Map.put(ctx.context, :session_id, Ecto.UUID.generate())

    patch = %{
      "name" => "Updated reminder",
      "agent_name" => "new-route",
      "provider" => nil,
      "delivery" => %{"mode" => "none"}
    }

    operation = operation(later, @update, %{"source" => "routine", "id" => id, "patch" => patch})

    assert {:ok, %{action: "automation.update"}} =
             AutomationMutation.classify(later, classification(operation, later))

    assert {:ok, %{content: content, structured: result} = output} =
             AutomationMutation.execute(operation)

    assert Jason.decode!(content) == result
    assert byte_size(Jason.encode!(output)) <= 65_536
    assert result["source"] == "routine"
    assert result["id"] == id
    assert result["persisted"] == true
    assert result["activation"] == "reloaded"
    assert result["cancellation"]["status"] == "not_requested"
    assert result["cancellation"]["cleanup_pending"] == false
    assert {:ok, saved} = Store.get(:routine, id)
    assert saved["name"] == "Updated reminder"
    assert saved["agent_name"] == "new-route"
    assert saved["automation_origin"] == receipt.routine["automation_origin"]
    assert saved["automation_origin"]["session_id"] == ctx.context.session_id
    assert Map.get(saved, "provider") == nil
    assert saved["delivery"] == %{"mode" => "none"}
    assert :ok = Store.reload(:routine)
    assert {:ok, ^saved} = Store.get(:routine, id)
  end

  test "native remove returns a bounded JSON cancellation request after deleting the exact configuration",
       ctx do
    receipt = create(ctx.context)
    id = receipt.id
    later = Map.put(ctx.context, :session_id, Ecto.UUID.generate())
    operation = operation(later, @remove, %{"source" => "routine", "id" => id})

    assert {:ok, %{action: "automation.remove"}} =
             AutomationMutation.classify(later, classification(operation, later))

    assert {:ok, %{content: content, structured: result} = output} =
             AutomationMutation.execute(operation)

    assert Jason.decode!(content) == result
    assert byte_size(Jason.encode!(output)) <= 65_536
    assert result["source"] == "routine"
    assert result["id"] == id
    assert result["persisted"] == true
    assert result["removed"] == true
    assert result["activation"] == "retired"
    assert result["cancellation"]["status"] == "cancellation_requested"
    assert result["cancellation"]["cleanup_pending"] == false
    assert result["cancellation"]["active_count"] == 0
    assert :ok = Store.reload(:routine)
    assert Store.list(:routine) == []
  end

  test "a long successful update retains its persisted identity when the optional projection is omitted",
       ctx do
    receipt = create(ctx.context)
    id = receipt.id
    name = String.duplicate("n", 40_000)

    operation =
      operation(ctx.context, @update, %{
        "source" => "routine",
        "id" => id,
        "patch" => %{"name" => name}
      })

    assert {:ok, %{content: content, structured: result} = output} =
             AutomationMutation.execute(operation)

    assert Jason.decode!(content) == result
    assert byte_size(Jason.encode!(output)) <= 65_536
    assert result["source"] == "routine"
    assert result["id"] == id
    assert result["persisted"] == true
    assert result["activation"] == "reloaded"
    assert result["projection_truncated"] == true
    assert result["cancellation"] == %{"status" => "not_requested", "cleanup_pending" => false}
    assert {:ok, saved} = Store.get(:routine, id)
    assert saved["name"] == name
  end

  defp create(context) do
    assert {:ok, receipt} =
             Routines.create_automation(
               %{
                 "prompt" => "Preserve the original source",
                 "enabled" => false,
                 "schedule" => %{"kind" => "every", "everyMs" => 600_000},
                 "provider" => "initial-provider"
               },
               context
             )

    receipt
  end

  defp operation(context, name, arguments) do
    Map.merge(context, %{
      tool_name: name,
      tool_revision: 1,
      arguments: arguments,
      backend_context:
        Map.put(context, :effect_deadline, fn -> {:ok, %{remaining_ms: 30_000}} end)
    })
  end

  defp classification(operation, context), do: %{operation | backend_context: context}
end
