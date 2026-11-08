defmodule Synapsis.Agent.Runtime.RunInventory do
  @moduledoc """
  Immutable intended run addresses in the existing runtime journal.

  A locator is persisted before native startup, not proof that a process started
  or an effect ran. Loading reads each exact aggregate without rewriting it or
  dispatching work. Coverage is limited to retained locators; the latest roster
  cannot reconstruct earlier overwritten addresses. Enumeration and aggregate
  reads are not a cross-record transaction.
  """

  alias Synapsis.Runtime.Store, as: Journal

  def root(session_id, store, run_id) do
    %{
      version: 1,
      session_id: session_id,
      namespace: store.namespace,
      run_id: run_id,
      incarnation: store.incarnation,
      kind: :root,
      name: "/root",
      parent_run_id: nil,
      agent_id: nil
    }
  end

  def root(session_id, store, run_id, mode_provenance) do
    root(session_id, store, run_id)
    |> Map.put(:mode_provenance, mode_provenance)
  end

  def child(session_id, store, identity, parent_run_id) do
    %{
      version: 1,
      session_id: session_id,
      namespace: store.namespace,
      run_id: identity.run_id,
      incarnation: identity.incarnation,
      kind: :child,
      name: identity.name,
      parent_run_id: parent_run_id,
      agent_id: identity.agent_id
    }
  end

  def child(session_id, store, identity, parent_run_id, mode_provenance) do
    child(session_id, store, identity, parent_run_id)
    |> Map.put(:mode_provenance, mode_provenance)
  end

  def completion(session_id, store, identity, parent_operation) do
    %{
      version: 1,
      session_id: session_id,
      namespace: store.namespace,
      run_id: identity.run_id,
      incarnation: identity.incarnation,
      kind: :llm_task,
      name: nil,
      agent_id: nil,
      parent_run_id: parent_operation.run_id,
      parent_incarnation: parent_operation.incarnation,
      parent_invocation_id: parent_operation.invocation_id
    }
  end

  def workflow_effect(session_id, store, identity, parent_operation, request) do
    completion(session_id, store, identity, parent_operation)
    |> Map.put(:kind, :workflow_effect)
    |> Map.put(:effect_request, request)
  end

  def retain(locator) do
    identity =
      {locator.namespace, locator.run_id, locator.incarnation}
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    Journal.put_fact(locator.session_id, :run_locator, identity, locator)
  end

  def load(session_id) do
    with {:ok, locators} <- Journal.list_facts(session_id, :run_locator) do
      locators
      |> Enum.sort_by(&{&1.namespace, &1.run_id, &1.incarnation})
      |> Enum.reduce_while({:ok, []}, fn locator, {:ok, entries} ->
        case Journal.load(locator.namespace, locator.run_id) do
          {:ok, aggregate} ->
            entry = %{locator: locator, aggregate: aggregate, availability: :present}
            {:cont, {:ok, [entry | entries]}}

          :not_found ->
            entry = %{locator: locator, aggregate: nil, availability: :absent}
            {:cont, {:ok, [entry | entries]}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, %{coverage: :retained_only, entries: Enum.reverse(entries)}}
        error -> error
      end
    end
  end
end
