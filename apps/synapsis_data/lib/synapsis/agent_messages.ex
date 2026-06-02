defmodule Synapsis.AgentMessages do
  @moduledoc """
  Agent-to-agent message delivery.

  ADR-006 C4: node-local coordination data in Concord under `coord/agent_messages/`,
  keyed by id. Secondary lookups (by recipient, ref, thread) scan the prefix and
  filter in memory — message volume is small and node-local. (Cluster delivery is
  future work — ADR-006 §10.)
  """
  alias Synapsis.AgentMessage

  @prefix "coord/agent_messages/"

  @spec create(map()) :: {:ok, AgentMessage.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    changeset = AgentMessage.changeset(%AgentMessage{}, attrs)

    if changeset.valid? do
      now = DateTime.utc_now()

      record =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> then(&%{&1 | id: &1.id || Ecto.UUID.generate(), inserted_at: now, updated_at: now})

      :ok = persist(record)
      {:ok, record}
    else
      {:error, changeset}
    end
  end

  @spec get(String.t()) :: AgentMessage.t() | nil
  def get(id) do
    case Concord.get(@prefix <> id) do
      {:ok, map} -> struct(AgentMessage, map)
      _ -> nil
    end
  end

  @spec get_by_ref(String.t()) :: AgentMessage.t() | nil
  def get_by_ref(ref), do: Enum.find(scan(), &(&1.ref == ref))

  @spec unread(String.t(), keyword()) :: [AgentMessage.t()]
  def unread(agent_id, opts \\ []) do
    scan()
    |> Enum.filter(&(&1.to_agent_id == agent_id and &1.status == "delivered"))
    |> recent(opts)
  end

  @spec history(String.t(), keyword()) :: [AgentMessage.t()]
  def history(agent_id, opts \\ []) do
    scan()
    |> Enum.filter(&(&1.from_agent_id == agent_id or &1.to_agent_id == agent_id))
    |> recent(opts)
  end

  @spec thread(String.t(), keyword()) :: [AgentMessage.t()]
  def thread(ref, opts \\ []) do
    scan()
    |> Enum.filter(&(&1.ref == ref or &1.in_reply_to == ref))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> take(opts)
  end

  @spec mark_read(AgentMessage.t()) :: {:ok, AgentMessage.t()}
  def mark_read(%AgentMessage{} = message), do: update_status(message, "read")

  @spec mark_all_read(String.t()) :: :ok
  def mark_all_read(agent_id) do
    agent_id |> unread() |> Enum.each(&update_status(&1, "read"))
    :ok
  end

  @spec update_status(AgentMessage.t(), String.t()) :: {:ok, AgentMessage.t()}
  def update_status(%AgentMessage{} = message, status) do
    updated = %{message | status: status, updated_at: DateTime.utc_now()}
    :ok = persist(updated)
    {:ok, updated}
  end

  @spec expire_stale() :: :ok
  def expire_stale do
    now = DateTime.utc_now()

    scan()
    |> Enum.filter(fn m ->
      m.status != "expired" and m.expires_at != nil and
        DateTime.compare(m.expires_at, now) == :lt
    end)
    |> Enum.each(&update_status(&1, "expired"))

    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp persist(%AgentMessage{} = record) do
    case Concord.put(@prefix <> record.id, Map.from_struct(record)) do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  defp scan do
    case Concord.prefix_scan(@prefix) do
      {:ok, pairs} -> Enum.map(pairs, fn {_k, v} -> struct(AgentMessage, v) end)
      _ -> []
    end
  end

  defp recent(messages, opts) do
    messages
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> take(opts)
  end

  defp take(messages, opts) do
    case Keyword.get(opts, :limit) do
      nil -> messages
      limit -> Enum.take(messages, limit)
    end
  end
end
