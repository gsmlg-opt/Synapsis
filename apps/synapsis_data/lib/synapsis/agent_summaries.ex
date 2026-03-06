defmodule Synapsis.AgentSummaries do
  @moduledoc "Query/persistence boundary for agent summaries."

  import Ecto.Query
  alias Synapsis.{AgentSummary, Repo}

  @spec put(map()) :: :ok | {:error, term()}
  def put(attrs) when is_map(attrs) do
    attrs = stringify_atoms(attrs)

    case %AgentSummary{}
         |> AgentSummary.changeset(attrs)
         |> Repo.insert(
           on_conflict: {:replace, [:content, :metadata, :updated_at]},
           conflict_target: [:scope, :scope_id, :kind]
         ) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec get(atom() | String.t(), String.t(), atom() | String.t()) ::
          {:ok, AgentSummary.t()} | {:error, :not_found}
  def get(scope, scope_id, kind) do
    scope_str = to_string(scope)
    kind_str = to_string(kind)

    case Repo.one(
           from(s in AgentSummary,
             where: s.scope == ^scope_str and s.scope_id == ^scope_id and s.kind == ^kind_str
           )
         ) do
      nil -> {:error, :not_found}
      summary -> {:ok, summary}
    end
  end

  @spec list(keyword()) :: [AgentSummary.t()]
  def list(filters \\ []) do
    AgentSummary
    |> apply_filters(filters)
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:scope, val} | rest]) do
    str = to_string(val)
    query |> where([s], s.scope == ^str) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:scope_id, val} | rest]) when is_binary(val) do
    query |> where([s], s.scope_id == ^val) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:kind, val} | rest]) do
    str = to_string(val)
    query |> where([s], s.kind == ^str) |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  defp stringify_atoms(attrs) do
    attrs
    |> Map.new(fn
      {:scope, v} when is_atom(v) -> {"scope", Atom.to_string(v)}
      {:kind, v} when is_atom(v) -> {"kind", Atom.to_string(v)}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
