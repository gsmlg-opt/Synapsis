defmodule Synapsis.Agent.Tools.ManagedInteractionCancelTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Agent.Tools.Policy

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.owner, :managed_backend_dispatched)
      {:ok, %{content: "executed"}}
    end
  end

  defmodule Hooks do
    def prepare_tool(invocation, context) do
      scope =
        invocation
        |> Map.take([:run_id, :incarnation, :catalog_revision])
        |> Map.merge(%{
          caller: "host",
          session_id: "managed-cancellation-proof",
          requester_id: "operator",
          permission_fingerprint: "permission-v1"
        })

      context =
        Map.merge(context, %{
          tool_scope: scope,
          tool_policy: %{
            scope: scope,
            tools: %{
              invocation.tool_name => %{
                tool_revision: invocation.tool_revision,
                classify: fn _ -> {:ok, %{action: "read", resource: "document:one"}} end
              }
            },
            decisions: %{{invocation.tool_name, "read", "document:one"} => :ask}
          },
          tool_readiness: %{
            scope: scope,
            tools: %{
              invocation.tool_name => %{tool_revision: invocation.tool_revision, status: :ready}
            }
          },
          tool_approval: %{
            mode: :interactive,
            scope: scope,
            expires_at: System.system_time(:millisecond) + 60_000,
            refresh: fn -> {:error, :cancelled_approval_must_not_refresh} end
          }
        })

      Policy.prepare_tool(invocation, context)
    end
  end

  # The persisted terminal record and its acknowledgement are separate boundaries.
  # This Store is ephemeral; it makes no Concord durability claim.
  defmodule Store do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      result = EphemeralStore.store(context.table, run, meta)

      case EphemeralStore.load(context.table, run.run_id) do
        {:ok, %{run: %{state: :cancelled}}} ->
          case :ets.take(context.gates, {:hold_terminal, run.run_id}) do
            [] -> result
            [_] -> await_ack(context, run.run_id, result)
          end

        _ ->
          result
      end
    end

    defp await_ack(context, run_id, result) do
      send(context.owner, {:managed_terminal_persisted, run_id, self(), context.table})

      receive do
        :ack -> result
      after
        5_000 -> {:error, Error.new(:execution_failure, "terminal acknowledgement withheld")}
      end
    end
  end

  setup do
    Code.ensure_loaded!(MultiAgent)

    assert function_exported?(MultiAgent, :cancel_interaction, 3),
           "Backplane #85 requires the published managed interaction cancellation API"

    owner = self()
    gates = :ets.new(:managed_interaction_cancel, [:set, :public])
    tasks = start_supervised!(Task.Supervisor)
    %{owner: owner, gates: gates, tasks: tasks}
  end

  test "managed approval cancellation waits for terminal acknowledgement before success", ctx do
    manager = start_manager(ctx)
    pending = spawn_pending(manager)
    correlation = pending.agent.pending_interaction.correlation
    run_id = correlation.run_id
    :ets.insert(ctx.gates, {{:hold_terminal, run_id}, true})

    cancellation =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        MultiAgent.cancel_interaction(manager, correlation, "Operator cancelled approval")
      end)

    assert_receive {:managed_terminal_persisted, ^run_id, store, table}, 1_000

    try do
      assert {:ok, %{run: %{state: :cancelled}}} = EphemeralStore.load(table, run_id)
      assert Task.yield(cancellation, 20) == nil
      assert {:ok, %{agents: [_]}} = MultiAgent.snapshot(manager)
      assert Task.yield(cancellation, 0) == nil

      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.resolve_interaction(manager, correlation, :approved)

      refute_receive :managed_backend_dispatched, 0
    after
      send(store, :ack)
    end

    assert :ok = Task.await(cancellation, 2_000)
    assert_receive {:codex_collaboration, %{type: :interrupted} = event}, 1_000
    assert event.interaction_id == correlation.interaction_id
    assert event.reason == "Operator cancelled approval"
    assert event.agent.pending_interaction == nil
    refute_receive :managed_backend_dispatched, 20
    refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 0
  end

  test "exact observed correlation cannot cancel replacement approval", ctx do
    manager = start_manager(ctx)
    pending = spawn_pending(manager)
    correlation = pending.agent.pending_interaction.correlation

    assert correlation == %{
             manager_id: pending.manager_id,
             agent_id: pending.agent.agent_id,
             run_id: pending.agent.run_id,
             incarnation: pending.agent.incarnation,
             interaction_id: pending.interaction_id
           }

    assert pending.agent.pending_interaction.request["kind"] == "permission"

    for field <- [:manager_id, :run_id, :interaction_id] do
      assert {:error, %Error{class: :resource_conflict}} =
               MultiAgent.cancel_interaction(
                 manager,
                 Map.put(correlation, field, "stale"),
                 "Cancel"
               )
    end

    assert :ok = MultiAgent.cancel_interaction(manager, correlation, "Cancel original")

    assert {:ok, _} =
             call(manager, "followup_task", %{"target" => "worker", "message" => "Again"})

    replacement = pending_interaction()
    assert replacement.agent.run_id != correlation.run_id

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.cancel_interaction(manager, correlation, "Stale cancellation")

    assert {:ok, %{agents: [current]}} = MultiAgent.snapshot(manager)
    assert current.run_id == replacement.agent.run_id
    assert current.status == :running
    assert current.pending_interaction == replacement.agent.pending_interaction
    refute_receive :managed_backend_dispatched, 20
  end

  test "persisted cancellation with a lost acknowledgement remains uncertain", ctx do
    manager = start_manager(ctx, commit_timeout: 100)
    pending = spawn_pending(manager)
    correlation = pending.agent.pending_interaction.correlation
    run_id = correlation.run_id
    :ets.insert(ctx.gates, {{:hold_terminal, run_id}, true})

    cancellation =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        MultiAgent.cancel_interaction(manager, correlation, "Cancel with lost acknowledgement")
      end)

    assert_receive {:managed_terminal_persisted, ^run_id, _store, table}, 1_000
    assert {:ok, %{run: %{state: :cancelled}}} = EphemeralStore.load(table, run_id)
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(cancellation, 2_000)
    assert {:ok, %{agents: [%{cleanup: :uncertain}]}} = MultiAgent.snapshot(manager)
    refute_receive :managed_backend_dispatched, 20
    refute_receive {:codex_collaboration, %{type: :interaction_resolved}}, 0
    refute_receive {:managed_terminal_persisted, _, _, _}, 20
  end

  defp start_manager(ctx, overrides \\ []) do
    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "root",
         parent_name: "/root",
         parent_authority: %{caller: "host", run_id: "root", grants: ["host::inspect"]},
         child_options: fn _request, run_id, _parent ->
           authority = %{
             caller: "host",
             run_id: run_id,
             grants: ["host::inspect"],
             tool_revision: 1
           }

           descriptor = %{
             tool_name: "host::inspect",
             tool_revision: 1,
             schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
             safety: %{read_only: true, retry_safe: true, parallel_safe: false},
             backend: Backend,
             backend_context: %{owner: ctx.owner}
           }

           {:ok, bundle} =
             ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority)

           script = fn _ ->
             [Proof.call("host::inspect", %{}), Proof.completed("Requesting approval")]
           end

           options = Proof.options(run_id, script)

           {:ok,
            Keyword.merge(
              options,
              [
                store: Store,
                context: %{table: options[:context], gates: ctx.gates, owner: ctx.owner},
                hooks: Hooks,
                registry: bundle.registry,
                tools: bundle.tools,
                authority: bundle.authority,
                schema_admission: :strict
              ] ++ overrides
            )}
         end}
      )

    assert {:ok, _} = MultiAgent.subscribe(manager)
    manager
  end

  defp spawn_pending(manager) do
    assert {:ok, _} =
             call(manager, "spawn_agent", %{
               "task_name" => "worker",
               "message" => "Inspect document"
             })

    pending_interaction()
  end

  defp pending_interaction do
    assert_receive {:codex_collaboration, %{type: :interaction_requested} = event}, 1_000
    event
  end

  defp call(manager, name, arguments) do
    MultiAgent.call(%{
      backend_context: %{runtime: manager, profile: :v2},
      run_id: "root",
      tool_name: name,
      arguments: arguments
    })
  end
end
