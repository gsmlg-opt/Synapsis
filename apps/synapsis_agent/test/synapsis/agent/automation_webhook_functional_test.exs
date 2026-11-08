defmodule Synapsis.Agent.AutomationWebhookFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.InputSchema
  alias Synapsis.Agent.Automation.Execution
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.Tools.{AutomationConfiguration, AutomationMutation}
  alias Synapsis.Config.Store

  @moduletag :tmp_dir
  @create "synapsis::automations_create"
  @update "synapsis::automations_update"
  @remove "synapsis::automations_remove"
  @target "http://localhost:4051/finished"
  @table :synapsis_config_routine
  @server {:via, Registry, {Synapsis.Config.Store.Registry, :routine}}

  setup %{tmp_dir: directory} do
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    entries = :ets.tab2list(@table)
    load_error = :sys.get_state(@server).load_error

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      :ets.delete_all_objects(@table)
      :ets.insert(@table, entries)
      :sys.replace_state(@server, &%{&1 | load_error: load_error})
      LocalScheduler.reload()
      File.rm_rf!(directory)
    end)

    System.put_env("SYNAPSIS_CONFIG_DIR", directory)
    File.write!(Store.file_path(:routine), "")
    assert :ok = Store.reload(:routine)

    %{
      context: %{
        session_id: Ecto.UUID.generate(),
        creator_agent_id: Ecto.UUID.generate(),
        requester_name: "main",
        run_id: "/root/webhook-foundation",
        incarnation: 1,
        catalog_revision: 1
      }
    }
  end

  test "create and update admit webhook at revision two while remove remains revision one", ctx do
    assert {:ok, [create]} = AutomationConfiguration.descriptors(ctx.context)
    assert {:ok, [update, remove]} = AutomationMutation.descriptors(ctx.context)
    assert create.tool_revision == 2
    assert update.tool_revision == 2
    assert remove.tool_revision == 1
    assert remove.tool_name == @remove

    for {descriptor, arguments} <- [
          {create, create_args()},
          {update, update_args(Ecto.UUID.generate(), %{"to" => @target})},
          {update, update_args(Ecto.UUID.generate(), %{"mode" => "webhook"})},
          {update, update_args(Ecto.UUID.generate(), %{"mode" => "none", "to" => nil})},
          {remove, %{"source" => "routine", "id" => Ecto.UUID.generate()}}
        ] do
      assert {:ok, _} = InputSchema.validate(descriptor.schema, arguments)
      backend = descriptor.backend
      invocation = operation(descriptor, arguments, ctx.context)
      classification = %{invocation | backend_context: ctx.context}
      assert {:ok, _} = backend.classify(ctx.context, classification)

      catalog = %{
        revision: 2,
        authority: %{run_id: ctx.context.run_id},
        registry: %{tools: %{descriptor.tool_name => descriptor}}
      }

      pinned = %{
        invocation
        | catalog_revision: 2,
          backend_context: Map.put(ctx.context, :catalog_snapshot, catalog)
      }

      assert {:ok, _} = backend.classify(ctx.context, pinned)
    end
  end

  test "native create and presence-aware update receipts expose the saved delivery target", ctx do
    assert {:ok, [create]} = AutomationConfiguration.descriptors(ctx.context)

    assert {:ok, %{structured: created, content: content}} =
             AutomationConfiguration.execute(operation(create, create_args(), ctx.context))

    assert Jason.decode!(content) == created
    assert created["persisted"] == true
    assert created["activation"] == "reloaded"
    assert created["delivery"] == %{"mode" => "webhook", "to" => @target}
    assert {:ok, initial} = Store.get(:routine, created["id"])
    assert initial["automation_contract_version"] == 1

    assert {:ok, [update]} = AutomationMutation.descriptors(ctx.context, [@update])
    next_target = "http://localhost:4052/updated"

    for {delivery, expected} <- [
          {%{"to" => next_target}, %{"mode" => "webhook", "to" => next_target}},
          {%{"mode" => "none"}, %{"mode" => "none", "to" => next_target}},
          {%{"mode" => "webhook"}, %{"mode" => "webhook", "to" => next_target}},
          {%{"mode" => "none", "to" => nil}, %{"mode" => "none"}}
        ] do
      assert {:ok, %{structured: receipt, content: text}} =
               AutomationMutation.execute(
                 operation(update, update_args(created["id"], delivery), ctx.context)
               )

      assert Jason.decode!(text) == receipt
      assert receipt["persisted"] == true
      assert receipt["activation"] == "reloaded"
      assert receipt["cancellation"]["status"] == "not_requested"
      assert receipt["delivery"] == expected
      assert {:ok, saved} = Store.get(:routine, created["id"])
      assert saved["delivery"] == expected
      assert saved["automation_origin"] == initial["automation_origin"]
    end
  end

  test "bounded native receipts retain mode and target when a long display name is truncated",
       ctx do
    assert {:ok, [create]} = AutomationConfiguration.descriptors(ctx.context)
    arguments = Map.put(create_args(), "name", String.duplicate("x", 40_000))

    assert {:ok, %{structured: created}} =
             AutomationConfiguration.execute(operation(create, arguments, ctx.context))

    assert created["projection_truncated"] == true
    assert created["persisted"] == true
    assert created["delivery"] == %{"mode" => "webhook", "to" => @target}

    assert {:ok, [update]} = AutomationMutation.descriptors(ctx.context, [@update])

    assert {:ok, %{structured: updated}} =
             AutomationMutation.execute(
               operation(update, update_args(created["id"], %{"to" => @target}), ctx.context)
             )

    assert updated["projection_truncated"] == true
    assert updated["persisted"] == true
    assert updated["delivery"] == created["delivery"]
  end

  for action <- [:create, :update] do
    @action action
    test "native #{@action} receipts bound a long valid target while preserving the stored URL",
         ctx do
      target = "http://localhost:4051/" <> String.duplicate("a", 40_000)
      assert {:ok, [create]} = AutomationConfiguration.descriptors(ctx.context)

      {descriptor, arguments, expected_id} =
        case @action do
          :create ->
            {create, put_in(create_args(), ["delivery", "to"], target), nil}

          :update ->
            assert {:ok, %{structured: initial}} =
                     AutomationConfiguration.execute(
                       operation(create, create_args(), ctx.context)
                     )

            assert {:ok, [update]} = AutomationMutation.descriptors(ctx.context, [@update])
            {update, update_args(initial["id"], %{"to" => target}), initial["id"]}
        end

      assert {:ok, _} = InputSchema.validate(descriptor.schema, arguments)
      backend = descriptor.backend
      assert {:ok, value} = backend.execute(operation(descriptor, arguments, ctx.context))
      receipt = value.structured
      assert Jason.decode!(value.content) == receipt
      assert receipt["source"] == "routine"
      assert {:ok, _} = Ecto.UUID.cast(receipt["id"])
      if expected_id, do: assert(receipt["id"] == expected_id)
      assert receipt["persisted"] == true
      assert receipt["activation"] == "reloaded"
      assert :ok = Store.reload(:routine)
      assert {:ok, saved} = Store.get(:routine, receipt["id"])
      assert saved["enabled"] == false
      assert saved["delivery"] == %{"mode" => "webhook", "to" => target}

      metadata =
        Execution.metadata(saved, %{
          "automation_ref" => %{"source" => "routine", "id" => receipt["id"]}
        })

      assert metadata["delivery"]["to"] == target
      assert metadata["automation_job"]["delivery"]["to"] == target
      assert byte_size(Jason.encode!(value)) <= 65_536
      assert receipt["projection_truncated"] == true
      assert receipt["delivery"]["mode"] == "webhook"
      assert receipt["delivery"]["to_truncated"] == true
      projected_target = receipt["delivery"]["to"]
      assert is_binary(projected_target) and byte_size(projected_target) > 0
      assert byte_size(projected_target) < byte_size(target)
      assert String.starts_with?(target, projected_target)
    end
  end

  test "scheduler metadata freezes the public admitted job beside ordinary custom metadata" do
    id = Ecto.UUID.generate()
    origin = %{"agent_id" => Ecto.UUID.generate(), "session_id" => Ecto.UUID.generate()}

    config = %{
      "id" => id,
      "name" => "Admitted webhook",
      "prompt" => "  原文\nexact authored bytes  \n",
      "schedule" => %{"kind" => "every", "everyMs" => 600_000, "anchorMs" => 123},
      "timezone" => "UTC",
      "enabled" => false,
      "agent_name" => "main",
      "automation_contract_version" => 1,
      "automation_origin" => origin,
      "session_target" => "isolated",
      "wake_mode" => "now",
      "delivery" => %{"mode" => "webhook", "to" => @target},
      "provider" => "configured-provider",
      "model" => "configured-model",
      "deleteAfterRun" => false,
      "max_runtime_ms" => 30_000,
      "no_overlap" => true,
      "createdAtMs" => 123,
      "metadata" => %{"custom_label" => "ordinary custom value"},
      "future_field" => "ordinary configuration extension"
    }

    for source <- ["routine", "heartbeat"] do
      base = %{
        "automation_ref" => %{"source" => source, "id" => id},
        "native_selection" => %{"selected" => [@create]},
        "routine_name" => config["name"]
      }

      metadata = Execution.metadata(config, base)

      expected =
        config
        |> Map.drop(~w(metadata future_field))
        |> Map.put("source", source)

      assert metadata["automation_job"] == expected
      assert metadata["automation_job"]["prompt"] == config["prompt"]
      assert metadata["automation_job"]["automation_origin"] == origin
      assert metadata["delivery"] == config["delivery"]
      assert metadata["automation_ref"] == base["automation_ref"]
      assert metadata["native_selection"] == base["native_selection"]
      assert metadata["custom_label"] == "ordinary custom value"
    end
  end

  defp create_args do
    %{
      "prompt" => "  Authored webhook work\n",
      "schedule" => %{"kind" => "every", "everyMs" => 600_000},
      "enabled" => false,
      "delivery" => %{"mode" => "webhook", "to" => @target}
    }
  end

  defp update_args(id, delivery),
    do: %{"source" => "routine", "id" => id, "patch" => %{"delivery" => delivery}}

  defp operation(descriptor, arguments, context) do
    Map.merge(context, %{
      tool_name: descriptor.tool_name,
      tool_revision: descriptor.tool_revision,
      arguments: arguments,
      backend_context:
        Map.put(context, :effect_deadline, fn -> {:ok, %{remaining_ms: 30_000}} end)
    })
  end
end
