defmodule Synapsis.Agent.Memory.SummaryStore do
  @moduledoc """
  DB-backed summary store for project/task/global rollups.
  Delegates to `Synapsis.AgentSummaries` for persistence.
  """

  alias Synapsis.Agent.Memory.Summary

  @spec put(map()) :: :ok | {:error, term()}
  def put(attrs) when is_map(attrs) do
    Synapsis.AgentSummaries.put(attrs)
  end

  @spec get(atom(), String.t(), atom()) :: {:ok, Summary.t()} | {:error, :not_found}
  def get(scope, scope_id, kind) do
    case Synapsis.AgentSummaries.get(scope, scope_id, kind) do
      {:ok, row} -> {:ok, to_summary(row)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec list(keyword()) :: [Summary.t()]
  def list(filters \\ []) do
    filters
    |> Synapsis.AgentSummaries.list()
    |> Enum.map(&to_summary/1)
  end

  defp to_summary(%Synapsis.AgentSummary{} = row) do
    %Summary{
      scope: safe_to_atom(row.scope),
      scope_id: row.scope_id,
      kind: safe_to_atom(row.kind),
      content: row.content,
      metadata: row.metadata || %{},
      updated_at: row.updated_at
    }
  end

  @known_atoms %{
    "global" => :global,
    "project" => :project,
    "task" => :task,
    "progress" => :progress,
    "decisions" => :decisions,
    "context" => :context,
    "summary" => :summary
  }

  defp safe_to_atom(str) when is_binary(str) do
    Map.get_lazy(@known_atoms, str, fn -> String.to_existing_atom(str) end)
  rescue
    ArgumentError -> str
  end
end
