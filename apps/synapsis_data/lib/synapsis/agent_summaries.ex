defmodule Synapsis.AgentSummaries do
  @moduledoc """
  Agent/task/global summary rollups.

  ADR-006 C4: node-local coordination data in Concord under `coord/agent_summaries/`,
  keyed by `scope/scope_id/kind` (upsert overwrites in place).
  """
  alias Concord.Turso, as: KV
  alias Synapsis.AgentSummary

  @prefix "coord/agent_summaries/"

  @spec put(map()) :: :ok | {:error, term()}
  def put(attrs) when is_map(attrs) do
    changeset = AgentSummary.changeset(%AgentSummary{}, attrs)

    if changeset.valid? do
      now = DateTime.utc_now()

      record =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> then(&%{&1 | id: &1.id || Ecto.UUID.generate(), updated_at: now})
        |> then(&%{&1 | inserted_at: &1.inserted_at || now})

      case KV.put(key(record.scope, record.scope_id, record.kind), Map.from_struct(record)) do
        :ok -> :ok
        {:ok, _} -> :ok
        other -> {:error, other}
      end
    else
      {:error, changeset}
    end
  end

  @spec get(atom() | String.t(), String.t(), atom() | String.t()) ::
          {:ok, AgentSummary.t()} | {:error, :not_found}
  def get(scope, scope_id, kind) do
    case KV.get(key(to_string(scope), scope_id, to_string(kind))) do
      {:ok, map} -> {:ok, struct(AgentSummary, map)}
      _ -> {:error, :not_found}
    end
  end

  @spec list(keyword()) :: [AgentSummary.t()]
  def list(filters \\ []) do
    {limit, filters} = Keyword.pop(filters, :limit, 200)

    scan()
    |> Enum.filter(&matches?(&1, filters))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp key(scope, scope_id, kind), do: @prefix <> "#{scope}/#{scope_id}/#{kind}"

  defp scan do
    case KV.prefix_scan(@prefix) do
      # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
      {:ok, pairs} ->
        Enum.map(pairs, fn {_k, v} -> struct(AgentSummary, Concord.Compression.decompress(v)) end)

      _ ->
        []
    end
  end

  defp matches?(summary, filters) do
    Enum.all?(filters, fn
      {:scope, v} -> summary.scope == to_string(v)
      {:scope_id, v} -> summary.scope_id == v
      {:kind, v} -> summary.kind == to_string(v)
      _ -> true
    end)
  end
end
