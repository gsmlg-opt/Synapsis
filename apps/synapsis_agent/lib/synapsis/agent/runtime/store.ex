defmodule Synapsis.Agent.Runtime.Store do
  @moduledoc "Durable Backplane runtime transitions acknowledged by Concord."
  @behaviour Backplane.AgentRuntime.Store

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Synapsis.Runtime.Store, as: DataStore

  @impl true
  def mode, do: :durable

  @impl true
  def capabilities do
    %{
      expected_revision: true,
      transition_events: true,
      outbox_intents: true,
      atomic_transition_outbox: true,
      recovery_records: true,
      artifact_references: true,
      incarnation_fencing: true
    }
  end

  @impl true
  def new(incarnation) when is_integer(incarnation) and incarnation >= 0 do
    {:ok, %{namespace: Ecto.UUID.generate(), incarnation: incarnation}}
  end

  @impl true
  def load(context, run_id, _opts \\ []) do
    case DataStore.load(context.namespace, run_id) do
      {:ok, aggregate} -> {:ok, aggregate}
      :not_found -> {:error, Error.new(:not_found, "runtime run not found")}
      {:error, reason} -> failure(reason)
    end
  end

  @impl true
  def store(context, record, meta) do
    with {:ok, run, transition, effects} <- Kernel.execute(record, meta.command),
         stage = %{
           run: run,
           transition: transition,
           effects: effects,
           outbox: Map.get(meta, :outbox, []),
           revision: run.expected_revision,
           incarnation: Map.get(run, :incarnation, 0)
         },
         {:ok, acknowledgement} <- acknowledge_commit(context, stage, meta) do
      {:ok, Map.merge(acknowledgement, %{outbox: stage.outbox, transition: transition})}
    end
  end

  @impl true
  def acknowledge_commit(context, stage, _meta) do
    case stage do
      %{
        run: %{run_id: run_id, expected_revision: revision} = run,
        revision: revision,
        incarnation: incarnation,
        transition: transition,
        effects: effects,
        outbox: outbox
      }
      when not is_nil(run_id) and is_integer(revision) and revision > 0 and
             is_integer(incarnation) and incarnation >= 0 and is_map(transition) and
             is_list(effects) and is_list(outbox) ->
        if Map.get(run, :incarnation, 0) == incarnation do
          case DataStore.commit(context.namespace, run_id, revision - 1, incarnation, stage) do
            :ok -> {:ok, %{revision: revision}}
            {:error, reason} -> failure(reason)
          end
        else
          {:error, Error.new(:validation, "stage incarnation does not match run")}
        end

      _ ->
        {:error, Error.new(:validation, "invalid stage")}
    end
  end

  @impl true
  def fence(context, run_id, expected_revision, current_incarnation, next_incarnation)
      when is_integer(expected_revision) and expected_revision >= 0 and
             is_integer(current_incarnation) and current_incarnation >= 0 and
             is_integer(next_incarnation) and next_incarnation > current_incarnation do
    with {:ok, aggregate} <- load(context, run_id),
         true <-
           aggregate.revision == expected_revision and
             aggregate.incarnation == current_incarnation,
         run =
           aggregate.run
           |> Map.put(:incarnation, next_incarnation)
           |> Map.put(:expected_revision, expected_revision + 1),
         fenced = %{
           aggregate
           | run: run,
             revision: expected_revision + 1,
             incarnation: next_incarnation
         },
         :ok <-
           DataStore.commit(
             context.namespace,
             run_id,
             expected_revision,
             current_incarnation,
             fenced
           ) do
      {:ok, %{revision: fenced.revision, run: run}}
    else
      false -> failure(:resource_conflict)
      {:error, %Error{}} = error -> error
      {:error, reason} -> failure(reason)
    end
  end

  def fence(_context, _run_id, _revision, _current, _next),
    do: {:error, Error.new(:validation, "invalid incarnation fence")}

  defp failure(:resource_conflict),
    do: {:error, Error.new(:resource_conflict, "runtime revision or incarnation conflict")}

  defp failure(reason),
    do:
      {:error,
       Error.new(:execution_failure, "runtime storage failed", details: %{reason: reason})}
end
