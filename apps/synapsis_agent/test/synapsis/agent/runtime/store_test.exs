defmodule Synapsis.Agent.Runtime.StoreTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, StoreConformance}
  alias Backplane.AgentRuntime.Store, as: Contract
  alias Synapsis.Agent.Runtime.Store

  defmodule FaultAdapter do
    def get(key, opts), do: Concord.Turso.get(key, opts)

    def txn(spec, opts) do
      if Process.delete({__MODULE__, :fail_next}) do
        {:error, :injected_failure}
      else
        Concord.Turso.txn(spec, opts)
      end
    end
  end

  setup do
    :ok = Synapsis.Session.Store.ensure_started()
    previous = Application.get_env(:synapsis_data, :runtime_store_adapter)
    Application.put_env(:synapsis_data, :runtime_store_adapter, FaultAdapter)

    on_exit(fn ->
      if previous do
        Application.put_env(:synapsis_data, :runtime_store_adapter, previous)
      else
        Application.delete_env(:synapsis_data, :runtime_store_adapter)
      end
    end)

    {:ok, context} = Store.new(1)
    %{context: context}
  end

  test "real Concord adapter satisfies every package durable-store conformance check", %{
    context: ctx
  } do
    assert {:ok, %{mode: :durable, checks: checks}} =
             StoreConformance.run(Store, ctx,
               run_id: Ecto.UUID.generate(),
               restart: fn context -> {:ok, Map.new(context)} end,
               fail_next_commit: fn _ ->
                 Process.put({FaultAdapter, :fail_next}, true)
                 :ok
               end,
               dependent_effect_count: fn _, _ -> 0 end
             )

    assert length(checks) == 9
  end

  test "stale executor cannot commit after incarnation fencing", %{context: ctx} do
    run = %{run_id: Ecto.UUID.generate(), incarnation: 1, expected_revision: 0, state: :queued}
    assert {:ok, %{revision: 1}} = Contract.store(Store, ctx, run, %{command: {:admit, 1, %{}}})
    assert {:ok, %{run: old}} = Store.load(ctx, run.run_id)
    assert {:ok, %{revision: 2}} = Contract.fence(Store, ctx, run.run_id, 1, 1, 2)

    assert {:error, %Error{class: :resource_conflict}} =
             Contract.store(Store, ctx, old, %{command: {:cancel, 2}})
  end

  test "invalid staged aggregate cannot create durable state", %{context: ctx} do
    assert {:error, %Error{class: :validation}} = Store.acknowledge_commit(ctx, %{}, %{})
  end
end
