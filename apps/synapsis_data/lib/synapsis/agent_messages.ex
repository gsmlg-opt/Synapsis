defmodule Synapsis.AgentMessages do
  @moduledoc """
  Node-local durable agent mail under `coord/agent_messages/` in Concord.

  The explicit fetch/query APIs distinguish missing records from unavailable
  storage. Legacy readers retain their successful return shapes. Replies and
  request acknowledgements use Concord's atomic `put_many/2`, serialized with
  expiry and status changes by a bounded node-local per-message lock. This lock
  is not a distributed transaction or an alternative storage implementation.

  Trusted options are an absolute monotonic `:deadline` and a `:kv` module
  (normally Concord.Turso). Each storage operation is bounded to five seconds
  and the remaining deadline. Storage failures are returned, never empty data.
  """
  alias Concord.Turso, as: KV
  alias Synapsis.AgentMessage

  @prefix "coord/agent_messages/"
  @statuses ~w(delivered read acknowledged expired)
  @operation_timeout 5_000

  def create(attrs, opts \\ []) do
    opts = bounded_opts(opts)

    with {:ok, record} <- build(attrs),
         :ok <- persist(record, opts) do
      {:ok, record}
    end
  end

  def fetch(id, opts \\ []) when is_binary(id) do
    case storage(:get, [@prefix <> id], bounded_opts(opts)) do
      {:ok, map} -> decode(map)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = error -> error
      nil -> {:error, :not_found}
      _ -> {:error, {:storage, :invalid_result}}
    end
  end

  def fetch_by_ref(ref, opts \\ []) do
    with {:ok, messages} <- scan(bounded_opts(opts)) do
      case Enum.filter(messages, &(&1.ref == ref)) do
        [] -> {:error, :not_found}
        [message] -> {:ok, message}
        _ -> {:error, :ambiguous_ref}
      end
    end
  end

  def get(id), do: legacy(fetch(id))
  def get_by_ref(ref), do: legacy(fetch_by_ref(ref))

  def query(action, agent_id, opts \\ []) do
    opts = bounded_opts(opts)

    with :ok <- valid_limit(opts),
         {:ok, messages} <- scan(opts),
         {:ok, selected} <- select(messages, action, agent_id, opts),
         {:ok, filtered} <- filter(selected, opts) do
      {:ok, filtered |> sort(action) |> take(opts)}
    end
  end

  def unread(agent_id, opts \\ []), do: legacy(query("unread", agent_id, opts))
  def history(agent_id, opts \\ []), do: legacy(query("history", agent_id, opts))

  def thread(ref, opts \\ []) do
    opts = bounded_opts(opts)

    with :ok <- valid_limit(opts),
         {:ok, messages} <- scan(opts),
         {:ok, selected} <- thread_messages(messages, ref, nil),
         {:ok, filtered} <- filter(selected, opts) do
      filtered |> sort("thread") |> take(opts)
    else
      {:error, :not_found} -> []
      {:error, _} = error -> error
    end
  end

  @doc "Atomically persists a response and acknowledges the still-open request."
  def reply(ref, responder, attrs, opts \\ []) do
    opts = bounded_opts(opts)

    with {:ok, original} <- fetch_by_ref(ref, opts) do
      locked([original.id], opts, fn ->
        with {:ok, request} <- fetch(original.id, opts),
             :ok <- replyable(request, responder),
             true <- attrs[:from_agent_id] == responder,
             {:ok, response} <-
               build(
                 Map.merge(attrs, %{
                   from_agent_id: responder,
                   to_agent_id: request.from_agent_id,
                   type: "response",
                   in_reply_to: request.id
                 })
               ),
             acknowledged = %{request | status: "acknowledged", updated_at: DateTime.utc_now()},
             :ok <- replyable(request, responder),
             :ok <- persist_many([response, acknowledged], opts) do
          {:ok, %{response: response, request: acknowledged}}
        else
          false -> {:error, :not_recipient}
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc "Expires only an open request; a committed response wins over cleanup."
  def expire_request(id, opts \\ []) do
    opts = bounded_opts(opts)

    locked([id], opts, fn ->
      with {:ok, current} <- fetch(id, opts) do
        if current.type == "request" and current.status in ~w(delivered read) do
          updated = %{current | status: "expired", updated_at: DateTime.utc_now()}
          with :ok <- persist(updated, opts), do: {:ok, updated}
        else
          {:ok, current}
        end
      end
    end)
  end

  def mark_read(%AgentMessage{} = message), do: update_status(message, "read")

  def mark_messages_read(messages, opts \\ []) do
    opts = bounded_opts(opts)
    ids = Enum.map(messages, & &1.id)

    locked(ids, opts, fn ->
      with {:ok, current} <- fetch_many(ids, opts) do
        updated =
          Enum.map(current, fn message ->
            if message.status == "delivered",
              do: %{message | status: "read", updated_at: DateTime.utc_now()},
              else: message
          end)

        changed = Enum.filter(updated, &(&1.status == "read"))
        with :ok <- persist_many(changed, opts), do: {:ok, updated}
      end
    end)
  end

  def mark_all_read(agent_id) do
    with {:ok, messages} <- query("unread", agent_id),
         {:ok, _} <- mark_messages_read(messages),
         do: :ok
  end

  def update_status(%AgentMessage{} = message, status, opts \\ []) do
    opts = bounded_opts(opts)

    if status in @statuses do
      locked([message.id], opts, fn ->
        with {:ok, current} <- fetch(message.id, opts) do
          if current.type == "request" and current.status in ~w(acknowledged expired) do
            {:ok, current}
          else
            updated = %{current | status: status, updated_at: DateTime.utc_now()}
            with :ok <- persist(updated, opts), do: {:ok, updated}
          end
        end
      end)
    else
      {:error, :invalid_status}
    end
  end

  def expire_stale do
    opts = bounded_opts([])
    now = DateTime.utc_now()

    with {:ok, messages} <- scan(opts) do
      messages
      |> Enum.filter(
        &(&1.status not in ~w(acknowledged expired) and &1.expires_at != nil and
            DateTime.compare(&1.expires_at, now) != :gt)
      )
      |> Enum.reduce_while(:ok, fn message, :ok ->
        result =
          if message.type == "request",
            do: expire_request(message.id, opts),
            else: update_status(message, "expired", opts)

        case result do
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp build(attrs) do
    changeset = AgentMessage.changeset(%AgentMessage{}, attrs)

    if changeset.valid? do
      now = DateTime.utc_now()
      record = Ecto.Changeset.apply_changes(changeset)
      {:ok, %{record | id: record.id || Ecto.UUID.generate(), inserted_at: now, updated_at: now}}
    else
      {:error, changeset}
    end
  end

  defp replyable(message, responder) do
    cond do
      message.type != "request" ->
        {:error, :not_request}

      message.to_agent_id != responder ->
        {:error, :not_recipient}

      message.status == "expired" ->
        {:error, :request_expired}

      message.status not in ~w(delivered read) ->
        {:error, :request_closed}

      message.expires_at != nil and
          DateTime.compare(message.expires_at, DateTime.utc_now()) != :gt ->
        {:error, :request_expired}

      true ->
        :ok
    end
  end

  defp select(messages, "unread", agent, _opts),
    do: {:ok, Enum.filter(messages, &(&1.to_agent_id == agent and &1.status == "delivered"))}

  defp select(messages, "history", agent, _opts),
    do: {:ok, Enum.filter(messages, &participant?(&1, agent))}

  defp select(messages, "thread", agent, opts),
    do: thread_messages(messages, Keyword.get(opts, :ref), agent)

  defp select(_, _, _, _), do: {:error, :invalid_action}

  defp thread_messages(messages, ref, agent) do
    case Enum.filter(messages, &(&1.ref == ref)) do
      [] ->
        {:error, :not_found}

      [root] ->
        if agent == nil or participant?(root, agent) do
          ids = descendants(messages, MapSet.new([root.id]))

          {:ok,
           Enum.filter(
             messages,
             &(MapSet.member?(ids, &1.id) and
                 (agent == nil or participant?(&1, agent)))
           )}
        else
          {:error, :not_participant}
        end

      _ ->
        {:error, :ambiguous_ref}
    end
  end

  defp descendants(messages, ids) do
    expanded =
      Enum.reduce(messages, ids, fn message, acc ->
        if MapSet.member?(ids, message.in_reply_to), do: MapSet.put(acc, message.id), else: acc
      end)

    if MapSet.equal?(ids, expanded), do: ids, else: descendants(messages, expanded)
  end

  defp participant?(message, agent),
    do: message.from_agent_id == agent or message.to_agent_id == agent

  defp filter(messages, opts) do
    with {:ok, since} <- since(Keyword.get(opts, :since)) do
      type = Keyword.get(opts, :type)

      {:ok,
       Enum.filter(messages, fn message ->
         (type == nil or message.type == type) and
           (since == nil or DateTime.compare(message.inserted_at, since) != :lt)
       end)}
    end
  end

  defp since(nil), do: {:ok, nil}
  defp since(%DateTime{} = since), do: {:ok, since}

  defp since(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, value, _} -> {:ok, value}
      _ -> {:error, :invalid_since}
    end
  end

  defp since(_), do: {:error, :invalid_since}

  defp sort(messages, "thread"), do: Enum.sort_by(messages, & &1.inserted_at, DateTime)
  defp sort(messages, _), do: Enum.sort_by(messages, & &1.inserted_at, {:desc, DateTime})

  defp valid_limit(opts) do
    case Keyword.get(opts, :limit) do
      nil -> :ok
      limit when is_integer(limit) and limit >= 0 -> :ok
      _ -> {:error, :invalid_limit}
    end
  end

  defp take(messages, opts) do
    case Keyword.get(opts, :limit) do
      nil -> messages
      limit when is_integer(limit) and limit >= 0 -> Enum.take(messages, limit)
    end
  end

  defp scan(opts) do
    case storage(:prefix_scan, [@prefix], opts) do
      {:ok, pairs} when is_list(pairs) ->
        Enum.reduce_while(pairs, {:ok, []}, fn {_key, value}, {:ok, acc} ->
          # WORKAROUND(upstream): gsmlg-dev/concord#23 — older prefix_scan skips decompression.
          case decode(Concord.Compression.decompress(value)) do
            {:ok, message} -> {:cont, {:ok, [message | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, _} = error ->
        error

      _ ->
        {:error, {:storage, :invalid_result}}
    end
  rescue
    _ -> {:error, {:storage, :invalid_record}}
  end

  defp decode(map) when is_map(map) do
    {:ok, struct!(AgentMessage, map)}
  rescue
    _ -> {:error, {:storage, :invalid_record}}
  end

  defp decode(_), do: {:error, {:storage, :invalid_record}}

  defp fetch_many(ids, opts) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, records} ->
      case fetch(id, opts) do
        {:ok, record} -> {:cont, {:ok, records ++ [record]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp persist(record, opts) do
    case storage(:put, [@prefix <> record.id, Map.from_struct(record)], opts) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      _ -> {:error, {:storage, :invalid_result}}
    end
  end

  defp persist_many([], _opts), do: :ok

  defp persist_many(records, opts) do
    pairs = Enum.map(records, &{@prefix <> &1.id, Map.from_struct(&1)})

    case storage(:put_many, [pairs], opts) do
      {:ok, results} when is_map(results) ->
        if map_size(results) == length(pairs) and
             Enum.all?(pairs, fn {key, _} -> results[key] == :ok end),
           do: :ok,
           else: {:error, {:storage, :invalid_result}}

      {:error, _} = error ->
        error

      _ ->
        {:error, {:storage, :invalid_result}}
    end
  end

  defp storage(function, args, opts) do
    remaining = opts[:deadline] - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      kv = Keyword.get(opts, :kv, KV)

      case apply(kv, function, args ++ [[timeout: min(remaining, @operation_timeout)]]) do
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, {:storage, reason}}
        result -> result
      end
    end
  rescue
    _ -> {:error, {:storage, :unavailable}}
  catch
    :exit, _ -> {:error, {:storage, :unavailable}}
  end

  defp bounded_opts(opts),
    do: Keyword.put_new(opts, :deadline, System.monotonic_time(:millisecond) + @operation_timeout)

  defp locked(ids, opts, fun), do: lock(Enum.sort(Enum.uniq(ids)), opts, fun)

  defp lock([], opts, fun) do
    if opts[:deadline] > System.monotonic_time(:millisecond), do: fun.(), else: {:error, :timeout}
  end

  defp lock([id | rest] = ids, opts, fun) do
    cond do
      opts[:deadline] <= System.monotonic_time(:millisecond) ->
        {:error, :timeout}

      :global.set_lock({{__MODULE__, id}, self()}, [node()], 0) ->
        try do
          lock(rest, opts, fun)
        after
          :global.del_lock({{__MODULE__, id}, self()}, [node()])
        end

      true ->
        receive do
        after
          min(5, max(0, opts[:deadline] - System.monotonic_time(:millisecond))) ->
            lock(ids, opts, fun)
        end
    end
  end

  defp legacy({:ok, value}), do: value
  defp legacy({:error, :not_found}), do: nil
  defp legacy({:error, _} = error), do: error
end
