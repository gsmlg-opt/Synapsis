defmodule Synapsis.AgentEvents do
  @moduledoc """
  Append-only agent event log.

  ADR-006 C4: node-local coordination data in Concord under `coord/agent_events/`.
  (The cluster/replicated form is future work — ADR-006 §10.)
  """
  alias Synapsis.AgentEvent

  @prefix "coord/agent_events/"

  @spec append(map()) :: :ok | {:error, term()}
  def append(attrs) when is_map(attrs) do
    changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

    if changeset.valid? do
      now = DateTime.utc_now()

      record =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now})

      key = @prefix <> DateTime.to_iso8601(now) <> "-" <> record.id

      case Concord.put(key, Map.from_struct(record)) do
        :ok -> :ok
        {:ok, _} -> :ok
        other -> {:error, other}
      end
    else
      {:error, changeset}
    end
  end

  @spec list(keyword()) :: [AgentEvent.t()]
  def list(filters \\ []) do
    {limit, filters} = Keyword.pop(filters, :limit, 500)

    scan()
    |> Enum.filter(&matches?(&1, filters))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.take(limit)
  end

  defp scan do
    case Concord.prefix_scan(@prefix) do
      {:ok, pairs} -> Enum.map(pairs, fn {_k, v} -> struct(AgentEvent, v) end)
      _ -> []
    end
  end

  defp matches?(event, filters) do
    Enum.all?(filters, fn
      {:agent_id, v} -> event.agent_id == v
      {:work_id, v} -> event.work_id == v
      {:event_type, v} -> event.event_type == to_string(v)
      _ -> true
    end)
  end
end
