defmodule Synapsis.AgentMessages do
  @moduledoc "Data access for persistent agent-to-agent messages."

  import Ecto.Query
  alias Synapsis.{AgentMessage, Repo}

  @doc "Insert a new agent message."
  @spec create(map()) :: {:ok, AgentMessage.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %AgentMessage{}
    |> AgentMessage.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get a message by ID."
  @spec get(String.t()) :: AgentMessage.t() | nil
  def get(id), do: Repo.get(AgentMessage, id)

  @doc "Get a message by ref."
  @spec get_by_ref(String.t()) :: AgentMessage.t() | nil
  def get_by_ref(ref) do
    Repo.get_by(AgentMessage, ref: ref)
  end

  @doc "List unread messages for an agent."
  @spec unread(String.t(), keyword()) :: [AgentMessage.t()]
  def unread(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    type = Keyword.get(opts, :type)

    AgentMessage
    |> where([m], m.to_agent_id == ^agent_id and m.status == "delivered")
    |> maybe_filter_type(type)
    |> order_by([m], asc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "List message history for an agent."
  @spec history(String.t(), keyword()) :: [AgentMessage.t()]
  def history(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    since = Keyword.get(opts, :since)
    type = Keyword.get(opts, :type)

    AgentMessage
    |> where([m], m.to_agent_id == ^agent_id or m.from_agent_id == ^agent_id)
    |> maybe_filter_since(since)
    |> maybe_filter_type(type)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Get a thread by following a ref chain."
  @spec thread(String.t(), keyword()) :: [AgentMessage.t()]
  def thread(ref, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    AgentMessage
    |> where(
      [m],
      m.ref == ^ref or
        m.in_reply_to in subquery(from(am in AgentMessage, where: am.ref == ^ref, select: am.id))
    )
    |> order_by([m], asc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Mark a message as read."
  @spec mark_read(AgentMessage.t()) :: {:ok, AgentMessage.t()} | {:error, Ecto.Changeset.t()}
  def mark_read(%AgentMessage{} = message) do
    message
    |> AgentMessage.mark_read_changeset()
    |> Repo.update()
  end

  @doc "Mark all unread messages for agent as read."
  @spec mark_all_read(String.t()) :: {non_neg_integer(), nil}
  def mark_all_read(agent_id) do
    AgentMessage
    |> where([m], m.to_agent_id == ^agent_id and m.status == "delivered")
    |> Repo.update_all(set: [status: "read", updated_at: DateTime.utc_now()])
  end

  @doc "Update message status."
  @spec update_status(AgentMessage.t(), String.t()) ::
          {:ok, AgentMessage.t()} | {:error, Ecto.Changeset.t()}
  def update_status(%AgentMessage{} = message, status) do
    message
    |> AgentMessage.changeset(%{status: status})
    |> Repo.update()
  end

  @doc "Expire old undelivered requests."
  @spec expire_stale() :: {non_neg_integer(), nil}
  def expire_stale do
    now = DateTime.utc_now()

    AgentMessage
    |> where([m], m.status == "delivered" and not is_nil(m.expires_at) and m.expires_at < ^now)
    |> Repo.update_all(set: [status: "expired", updated_at: now])
  end

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [m], m.type == ^type)

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> where(query, [m], m.inserted_at >= ^dt)
      _ -> query
    end
  end

  defp maybe_filter_since(query, %DateTime{} = since) do
    where(query, [m], m.inserted_at >= ^since)
  end
end
