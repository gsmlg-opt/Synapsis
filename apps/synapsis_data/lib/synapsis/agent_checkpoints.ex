defmodule Synapsis.AgentCheckpoints do
  @moduledoc "Query/persistence boundary for agent checkpoints."

  import Ecto.Query
  alias Synapsis.{AgentCheckpoint, Repo}

  @spec put(map()) :: :ok | {:error, term()}
  def put(attrs) when is_map(attrs) do
    attrs = serialize_attrs(attrs)

    case %AgentCheckpoint{}
         |> AgentCheckpoint.changeset(attrs)
         |> Repo.insert(
           on_conflict: {:replace, [:graph, :node, :status, :state, :ctx, :error, :updated_at]},
           conflict_target: :run_id
         ) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec get(String.t()) :: {:ok, AgentCheckpoint.t()} | {:error, :not_found}
  def get(run_id) when is_binary(run_id) do
    case Repo.one(from(c in AgentCheckpoint, where: c.run_id == ^run_id)) do
      nil -> {:error, :not_found}
      checkpoint -> {:ok, checkpoint}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(run_id) when is_binary(run_id) do
    from(c in AgentCheckpoint, where: c.run_id == ^run_id) |> Repo.delete_all()
    :ok
  end

  @spec list(keyword()) :: [AgentCheckpoint.t()]
  def list(filters \\ []) do
    AgentCheckpoint
    |> apply_filters(filters)
    |> order_by([c], desc: c.updated_at)
    |> Repo.all()
  end

  @spec clear() :: :ok
  def clear do
    Repo.delete_all(AgentCheckpoint)
    :ok
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:run_id, val} | rest]) when is_binary(val) do
    query |> where([c], c.run_id == ^val) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:status, val} | rest]) when is_atom(val) do
    str = Atom.to_string(val)
    query |> where([c], c.status == ^str) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:status, val} | rest]) when is_binary(val) do
    query |> where([c], c.status == ^val) |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  defp serialize_attrs(attrs) do
    attrs
    |> Map.new(fn
      {:status, v} when is_atom(v) -> {"status", Atom.to_string(v)}
      {:node, v} when is_atom(v) -> {"node", Atom.to_string(v)}
      {:node, nil} -> {"node", nil}
      {:error, v} -> {"error", serialize_error(v)}
      {:state, v} when is_map(v) -> {"state", json_safe(v)}
      {:ctx, v} when is_map(v) -> {"ctx", json_safe(v)}
      {:graph, v} when is_map(v) -> {"graph", v}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp serialize_error(nil), do: nil
  defp serialize_error(error) when is_map(error) and not is_struct(error), do: json_safe(error)

  defp serialize_error(error) do
    %{"type" => "term", "value" => inspect(error)}
  end

  defp json_safe(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {to_string(k), json_safe(v)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(true), do: true
  defp json_safe(false), do: false
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp json_safe(%Date{} = d), do: Date.to_iso8601(d)
  defp json_safe(value) when is_struct(value), do: json_safe(Map.from_struct(value))
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value), do: value
end
