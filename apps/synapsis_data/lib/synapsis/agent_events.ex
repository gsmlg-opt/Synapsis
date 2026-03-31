defmodule Synapsis.AgentEvents do
  @moduledoc "Query/persistence boundary for agent events."

  import Ecto.Query
  alias Synapsis.{AgentEvent, Repo}

  @spec append(map()) :: :ok | {:error, term()}
  def append(attrs) when is_map(attrs) do
    attrs = stringify_atoms(attrs)

    case %AgentEvent{} |> AgentEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec list(keyword()) :: [AgentEvent.t()]
  def list(filters \\ []) do
    {limit, filters} = Keyword.pop(filters, :limit, 500)

    AgentEvent
    |> apply_filters(filters)
    |> order_by([e], asc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:project_id, val} | rest]) when is_binary(val) do
    query |> where([e], e.project_id == ^val) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:work_id, val} | rest]) when is_binary(val) do
    query |> where([e], e.work_id == ^val) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:event_type, val} | rest]) when is_atom(val) do
    str = Atom.to_string(val)
    query |> where([e], e.event_type == ^str) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:event_type, val} | rest]) when is_binary(val) do
    query |> where([e], e.event_type == ^val) |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  defp stringify_atoms(attrs) do
    attrs
    |> Map.new(fn
      {:event_type, v} when is_atom(v) -> {"event_type", Atom.to_string(v)}
      {:payload, v} when is_map(v) -> {"payload", json_safe(v)}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
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
