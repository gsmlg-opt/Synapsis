defmodule Synapsis.LocalAgentThreads do
  @moduledoc """
  Threads Synapsis created on a local agent that cannot list its own threads.

  samgita_protocol `sessions.v1` has no `thread/list`, so a Sigma agent's
  thread list is the threads Synapsis started there, newest first.

  Each thread is one Concord key `<prefix><agent_id>/<created_at>/<base64url thread_id>`
  with no payload, so a newest-first key listing is the whole read. Data only.
  """

  @prefix "coord/local_agents/threads/"
  @timeout 5_000

  @type summary :: %{id: String.t(), title: nil, updated_at: String.t()}

  @spec record(String.t(), String.t()) :: :ok | {:error, term()}
  def record(agent_id, thread_id) when is_binary(agent_id) and is_binary(thread_id) do
    created_at = DateTime.utc_now() |> DateTime.to_iso8601()

    key =
      agent_prefix(agent_id) <> created_at <> "/" <> Base.url_encode64(thread_id, padding: false)

    case Concord.Turso.put(key, true, timeout: @timeout) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # WORKAROUND(upstream): gsmlg-opt/Samgita#2 — remove once `thread/list` is in
  # samgita_protocol and Sigma implements it; list through the agent instead.
  @spec list(String.t(), pos_integer()) :: {:ok, [summary]} | {:error, term()}
  def list(agent_id, limit) when is_binary(agent_id) and is_integer(limit) and limit > 0 do
    prefix = agent_prefix(agent_id)

    case Concord.Turso.list(
           prefix: prefix,
           order: :desc,
           limit: limit,
           keys_only: true,
           timeout: @timeout
         ) do
      {:ok, records, _page} -> {:ok, Enum.flat_map(records, &summary(&1.key, prefix))}
      {:error, _} = error -> error
    end
  end

  defp summary(key, prefix) do
    with [created_at, encoded] <- key |> String.replace_prefix(prefix, "") |> String.split("/"),
         {:ok, thread_id} <- Base.url_decode64(encoded, padding: false) do
      [%{id: thread_id, title: nil, updated_at: created_at}]
    else
      _ -> []
    end
  end

  # Agent ids are UUIDs; encode anyway so no id can reach into another prefix.
  defp agent_prefix(agent_id), do: @prefix <> Base.url_encode64(agent_id, padding: false) <> "/"
end
