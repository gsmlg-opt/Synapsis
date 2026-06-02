defmodule Synapsis.AgentCheckpoints do
  @moduledoc """
  Resumable graph-execution checkpoints.

  ADR-006 C4: node-local coordination data in Concord under `coord/agent_checkpoints/`,
  keyed by `run_id` (upsert overwrites in place).
  """
  alias Synapsis.AgentCheckpoint

  @prefix "coord/agent_checkpoints/"

  @spec put(map()) :: :ok | {:error, term()}
  def put(attrs) when is_map(attrs) do
    changeset = AgentCheckpoint.changeset(%AgentCheckpoint{}, attrs)

    if changeset.valid? do
      now = DateTime.utc_now()

      record =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> then(&%{&1 | id: &1.id || Ecto.UUID.generate(), updated_at: now})
        |> then(&%{&1 | inserted_at: &1.inserted_at || now})

      case Concord.put(@prefix <> record.run_id, Map.from_struct(record)) do
        :ok -> :ok
        {:ok, _} -> :ok
        other -> {:error, other}
      end
    else
      {:error, changeset}
    end
  end

  @spec get(String.t()) :: AgentCheckpoint.t() | nil
  def get(run_id) when is_binary(run_id) do
    case Concord.get(@prefix <> run_id) do
      {:ok, map} -> struct(AgentCheckpoint, map)
      _ -> nil
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(run_id) when is_binary(run_id) do
    Concord.delete(@prefix <> run_id)
    :ok
  end

  @spec list(keyword()) :: [AgentCheckpoint.t()]
  def list(filters \\ []) do
    status = Keyword.get(filters, :status)

    scan()
    |> then(fn cps -> if status, do: Enum.filter(cps, &(&1.status == status)), else: cps end)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  @spec clear() :: :ok
  def clear do
    case Concord.prefix_scan(@prefix) do
      {:ok, pairs} -> Concord.delete_many(Enum.map(pairs, fn {k, _v} -> k end))
      _ -> :ok
    end

    :ok
  end

  defp scan do
    case Concord.prefix_scan(@prefix) do
      {:ok, pairs} -> Enum.map(pairs, fn {_k, v} -> struct(AgentCheckpoint, v) end)
      _ -> []
    end
  end
end
