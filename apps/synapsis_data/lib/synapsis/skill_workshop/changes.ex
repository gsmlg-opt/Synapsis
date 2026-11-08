defmodule Synapsis.SkillWorkshop.Changes do
  @moduledoc """
  Durable workshop change facts in the configured file-backed Concord store.

  Each source-shaped change has a UUID payload key. A compact Agent index keeps
  the newest 500 references, ordered by source timestamp and then append ordinal.
  Appending the payload, updating the index and removing stale current payloads
  share one conditional transaction. Concord retains its own revision history.

  Reads capture one committed revision for both the index and selected payloads.
  Every operation checks the original local store owner and shares the caller's
  absolute monotonic deadline, capped at five seconds. Native work already in
  progress cannot be forcibly interrupted. A successful commit acknowledgement
  remains successful; an unknown transaction outcome is never retried here.

  This module stores audit facts only. It does not write skill documents, publish
  discovery changes, execute source SQL or introduce another runtime or database.
  """

  alias Concord.KV
  alias Concord.KV.Record

  @prefix "coord/skill_workshop/agents/"
  @maximum_changes 500
  @maximum_timeout 5_000
  @attempts 3
  @actions ~w(create patch write_file remove_file archive restore)
  @actors ~w(agent review curator user)
  @required ~w(id agentId skillName action actor summary createdAtMs)
  @optional ~w(versionId sessionKey runId)

  @doc "Append one exact change and acknowledge only its committed transaction."
  @spec append(map(), integer()) :: {:ok, map()} | {:error, term()}
  def append(change, deadline) do
    with :ok <- validate_change(change),
         {:ok, context} <- capture(deadline) do
      append_change(context, change, @attempts)
    end
  end

  @doc "List source-shaped changes newest first, with exclusive time and exact run filters."
  @spec list(binary(), keyword(), integer()) :: {:ok, [map()]} | {:error, term()}
  def list(agent_id, opts, deadline) do
    with true <- canonical_id?(agent_id),
         {:ok, selection} <- selection(opts),
         {:ok, context} <- capture(deadline),
         {:ok, revision} <- read_revision(context),
         {:ok, index} <- snapshot_index(context, agent_id, revision),
         entries = before_time(index.entries, selection.before_ms),
         {:ok, changes} <-
           read_changes(context, agent_id, revision, entries, selection, []),
         {:ok, _remaining} <- check(context) do
      {:ok, changes}
    else
      false -> {:error, :invalid_agent_id}
      error -> error
    end
  end

  defp append_change(context, change, attempts) do
    agent_id = change["agentId"]

    with {:ok, index, comparison} <- current_index(context, agent_id),
         :ok <- new_change(index, change["id"]) do
      ordinal = index.ordinal + 1
      entry = %{id: change["id"], created_at_ms: change["createdAtMs"], ordinal: ordinal}

      {retained, dropped} =
        [entry | index.entries]
        |> newest_first()
        |> Enum.split(@maximum_changes)

      updated = %{schema: 1, ordinal: ordinal, entries: retained}
      payload_key = change_key(agent_id, change["id"])

      operations = [
        {:put, payload_key, change, %{}},
        {:put, index_key(agent_id), updated, %{}}
      ]

      deletes = Enum.map(dropped, &{:delete, {:key, change_key(agent_id, &1.id)}, %{}})

      spec = %{
        compare: [comparison, {:exists, payload_key, :==, false}],
        success: operations ++ deletes,
        failure: []
      }

      case commit(context, spec) do
        {:ok, %{succeeded: true}} ->
          {:ok, change}

        {:ok, %{succeeded: false}} when attempts > 1 ->
          append_change(context, change, attempts - 1)

        {:ok, %{succeeded: false}} ->
          {:error, :resource_conflict}

        {:error, _} = error ->
          error
      end
    end
  end

  defp new_change(index, id) do
    if Enum.any?(index.entries, &(&1.id == id)),
      do: {:error, :change_exists},
      else: :ok
  end

  defp current_index(context, agent_id) do
    key = index_key(agent_id)

    case read(context, &KV.get(key, engine: :turso, metadata: true, timeout: &1)) do
      {:error, :not_found} ->
        {:ok, empty_index(), {:exists, key, :==, false}}

      {:ok, %Record{value: index, mod_revision: revision}}
      when is_integer(revision) and revision > 0 ->
        with :ok <- validate_index(index),
             do: {:ok, index, {:mod_revision, key, :==, revision}}

      {:ok, _} ->
        {:error, :invalid_record}

      {:error, _} = error ->
        error
    end
  end

  defp snapshot_index(context, agent_id, revision) do
    case read(
           context,
           &KV.get(index_key(agent_id), engine: :turso, revision: revision, timeout: &1)
         ) do
      {:error, :not_found} -> {:ok, empty_index()}
      {:ok, index} -> with :ok <- validate_index(index), do: {:ok, index}
      {:error, _} = error -> error
    end
  end

  defp read_revision(context) do
    case read(context, &KV.revision(engine: :turso, timeout: &1)) do
      {:ok, revision} when is_integer(revision) and revision >= 0 -> {:ok, revision}
      {:ok, _} -> {:error, :invalid_record}
      {:error, _} = error -> error
    end
  end

  defp read_changes(_context, _agent_id, _revision, [], _selection, changes),
    do: {:ok, Enum.reverse(changes)}

  defp read_changes(_context, _agent_id, _revision, _entries, %{limit: 0}, changes),
    do: {:ok, Enum.reverse(changes)}

  defp read_changes(context, agent_id, revision, [entry | rest], selection, changes) do
    key = change_key(agent_id, entry.id)

    with {:ok, change} <-
           read(context, &KV.get(key, engine: :turso, revision: revision, timeout: &1)),
         :ok <- validate_change(change),
         true <-
           change["agentId"] == agent_id and change["id"] == entry.id and
             change["createdAtMs"] == entry.created_at_ms do
      if is_nil(selection.run_id) or change["runId"] == selection.run_id do
        read_changes(
          context,
          agent_id,
          revision,
          rest,
          %{selection | limit: selection.limit - 1},
          [
            change | changes
          ]
        )
      else
        read_changes(context, agent_id, revision, rest, selection, changes)
      end
    else
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  defp before_time(entries, nil), do: entries
  defp before_time(entries, before_ms), do: Enum.filter(entries, &(&1.created_at_ms < before_ms))

  defp selection(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit, :before_ms, :run_id] == [] do
      limit = Keyword.get(opts, :limit, 50)
      limit = if is_nil(limit), do: 50, else: limit
      before_ms = Keyword.get(opts, :before_ms)
      run_id = Keyword.get(opts, :run_id)

      if is_number(limit) and (is_nil(before_ms) or is_number(before_ms)) and
           (is_nil(run_id) or text?(run_id)) do
        {:ok,
         %{
           limit: limit |> trunc() |> max(1) |> min(@maximum_changes),
           before_ms: before_ms,
           run_id: if(run_id == "", do: nil, else: run_id)
         }}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp selection(_), do: {:error, :invalid_options}

  defp validate_change(change) when is_map(change) do
    valid =
      Map.keys(change) -- (@required ++ @optional) == [] and
        Enum.all?(@required, &Map.has_key?(change, &1)) and
        canonical_id?(change["id"]) and canonical_id?(change["agentId"]) and
        text?(change["skillName"]) and change["skillName"] != "" and
        change["action"] in @actions and change["actor"] in @actors and
        text?(change["summary"]) and is_integer(change["createdAtMs"]) and
        Enum.all?(@optional, fn key -> not Map.has_key?(change, key) or text?(change[key]) end)

    if valid, do: :ok, else: {:error, :invalid_change}
  end

  defp validate_change(_), do: {:error, :invalid_change}

  defp empty_index, do: %{schema: 1, ordinal: 0, entries: []}

  defp validate_index(%{schema: 1, ordinal: ordinal, entries: entries})
       when is_integer(ordinal) and ordinal >= 0 and is_list(entries) do
    valid =
      length(entries) <= @maximum_changes and
        Enum.all?(entries, &valid_entry?(&1, ordinal)) and
        entries == newest_first(entries) and
        unique?(entries, & &1.id) and unique?(entries, & &1.ordinal)

    if valid, do: :ok, else: {:error, :invalid_record}
  end

  defp validate_index(_), do: {:error, :invalid_record}

  defp valid_entry?(%{id: id, created_at_ms: time, ordinal: ordinal}, maximum),
    do:
      canonical_id?(id) and is_integer(time) and is_integer(ordinal) and ordinal > 0 and
        ordinal <= maximum

  defp valid_entry?(_, _), do: false

  defp unique?(entries, project) do
    values = Enum.map(entries, project)
    values == Enum.uniq(values)
  end

  defp newest_first(entries), do: Enum.sort_by(entries, &{&1.created_at_ms, &1.ordinal}, :desc)

  defp capture(deadline) when is_integer(deadline) do
    now = System.monotonic_time(:millisecond)
    config = Application.get_env(:concord, :turso, [])
    database = Keyword.get(config, :database)
    owner = Process.whereis(Concord.Turso.DB)

    cond do
      deadline <= now ->
        {:error, :timeout}

      Keyword.get(config, :enabled, false) and is_binary(database) and database != "" and
        database != ":memory:" and
        not String.starts_with?(database, ["file:", "libsql:", "http:", "https:"]) and
        is_nil(Keyword.get(config, :remote_url)) and is_pid(owner) and node(owner) == node() ->
        {:ok, %{owner: owner, deadline: min(deadline, now + @maximum_timeout)}}

      true ->
        {:error, :storage_unavailable}
    end
  end

  defp capture(_), do: {:error, :invalid_deadline}

  defp check(%{owner: owner, deadline: deadline}) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Process.whereis(Concord.Turso.DB) != owner -> {:error, :owner_changed}
      remaining <= 0 -> {:error, :timeout}
      true -> {:ok, remaining}
    end
  end

  defp read(context, operation) do
    with {:ok, remaining} <- check(context) do
      result = invoke(operation, remaining)
      with {:ok, _remaining} <- check(context), do: result
    end
  end

  defp commit(context, spec) do
    with {:ok, remaining} <- check(context) do
      case invoke(&Concord.Turso.txn(spec, timeout: &1), remaining) do
        {:ok, %{succeeded: succeeded}} = result when is_boolean(succeeded) -> result
        {:error, reason} -> {:error, {:unknown_outcome, reason}}
        _ -> {:error, {:unknown_outcome, :invalid_transaction_result}}
      end
    end
  end

  defp invoke(operation, timeout) do
    operation.(timeout)
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, :timeout -> {:error, :timeout}
    _, _ -> {:error, :storage_unavailable}
  end

  defp canonical_id?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp canonical_id?(_), do: false
  defp text?(text), do: is_binary(text) and String.valid?(text)
  defp index_key(agent_id), do: @prefix <> agent_id <> "/index"
  defp change_key(agent_id, id), do: @prefix <> agent_id <> "/changes/" <> id
end
