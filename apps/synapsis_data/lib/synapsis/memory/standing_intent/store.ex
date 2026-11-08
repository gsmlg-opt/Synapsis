defmodule Synapsis.Memory.StandingIntent.Store do
  @moduledoc """
  Revision-pinned, Data-owned storage for opaque standing-intent rows.

  Individual payload, creation-order, generation and Agent directory keys share
  one conditional transaction. Snapshots retain the local file-backed store
  owner and committed revision; later writes do not change their reads. Payloads
  are preserved without interpreting intent status, scope, keywords or lifecycle.

  Each operation shares the caller's absolute monotonic deadline, capped at five
  seconds. An acknowledged commit remains successful after its deadline; an
  uncertain dispatched transaction is reported without retrying.
  """

  alias Concord.KV
  alias Concord.KV.Record

  @prefix "coord/memory/standing_intents/v1/"
  @maximum_timeout 5_000
  @minimum_time -9_223_372_036_854_775_808
  @maximum_time 9_223_372_036_854_775_807
  @time_offset 9_223_372_036_854_775_808

  @opaque snapshot ::
            {:standing_intent_snapshot, pid(), binary(), non_neg_integer(), non_neg_integer(),
             non_neg_integer()}

  @doc "Capture an Agent generation and its committed storage revision."
  @spec snapshot(binary(), integer()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(agent_id, deadline) do
    with true <- canonical_id?(agent_id),
         {:ok, context} <- capture(deadline),
         {:ok, revision} <- read_revision(context),
         {:ok, generation, mod_revision} <- read_generation(context, agent_id, revision),
         {:ok, _remaining} <- check(context) do
      {:ok,
       {:standing_intent_snapshot, context.owner, agent_id, revision, generation, mod_revision}}
    else
      false -> {:error, :invalid_agent_id}
      error -> error
    end
  end

  @doc "Read the captured generation without storage access."
  @spec generation(snapshot()) :: non_neg_integer()
  def generation(
        {:standing_intent_snapshot, _owner, _agent, _revision, generation, _mod_revision}
      ),
      do: generation

  @doc "Read one unchanged payload at the snapshot revision."
  @spec get(snapshot(), binary(), integer()) :: {:ok, map()} | {:error, term()}
  def get(snapshot, id, deadline) do
    with {:ok, context, agent_id, revision} <- snapshot_context(snapshot, deadline),
         true <- canonical_id?(id),
         {:ok, envelope} <- read_value(context, row_key(agent_id, id), revision),
         {:ok, row} <- payload(envelope, agent_id, id),
         :ok <- verify_order(context, agent_id, row, revision),
         {:ok, _remaining} <- check(context) do
      {:ok, row}
    else
      false -> {:error, :invalid_intent_id}
      error -> error
    end
  end

  @doc "Read an ordinary creation-order page without truncating the stored inventory."
  @spec list_page(snapshot(), keyword(), integer()) :: {:ok, map()} | {:error, term()}
  def list_page(snapshot, opts, deadline) do
    with {:ok, context, agent_id, revision} <- snapshot_context(snapshot, deadline),
         {:ok, limit, cursor} <- page_options(opts),
         {:ok, after_key} <- order_cursor(cursor, snapshot, agent_id),
         {:ok, records, page} <-
           read_page(context, order_prefix(agent_id), after_key, revision, limit),
         {:ok, rows} <- read_ordered_rows(context, agent_id, revision, records),
         {:ok, _remaining} <- check(context) do
      next =
        if page.has_more,
          do: {:standing_intent_cursor, snapshot, page.last_key},
          else: nil

      {:ok, %{rows: rows, next_cursor: next}}
    end
  end

  @doc "Atomically write complete rows against their captured generation and revisions."
  @spec commit(snapshot(), [map()], integer()) :: {:ok, map()} | {:error, term()}
  def commit(snapshot, rows, deadline), do: commit(snapshot, rows, deadline, [])

  @doc """
  Commit with an optional `before_commit` admission callback.

  The callback runs after historical row preparation, immediately before public
  transaction dispatch. It returns `:ok` or an error tuple; it is never persisted
  or run inside the native transaction. Owner and deadline are checked again
  after admission. A successful transaction acknowledgement is not rechecked.
  """
  @spec commit(snapshot(), [map()], integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(snapshot, rows, deadline, opts) do
    with {:ok, admission} <- commit_options(opts),
         {:ok, context, agent_id, revision} <- snapshot_context(snapshot, deadline),
         :ok <- validate_rows(rows),
         {:ok, compares, operations} <- prepare_rows(context, agent_id, revision, rows) do
      next_generation = generation(snapshot) + 1

      spec = %{
        compare: [generation_compare(snapshot) | compares],
        success:
          operations ++
            [
              {:put, generation_key(agent_id),
               %{schema: 1, kind: :generation, agent_id: agent_id, generation: next_generation},
               %{}},
              {:put, directory_key(agent_id), %{schema: 1, kind: :agent, agent_id: agent_id}, %{}}
            ],
        failure: []
      }

      with :ok <- admit(admission) do
        case transact(context, spec) do
          {:ok, %{succeeded: true}} -> {:ok, %{generation: next_generation}}
          {:ok, %{succeeded: false}} -> {:error, :resource_conflict}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp commit_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:before_commit] == [] do
      case Keyword.get(opts, :before_commit) do
        nil -> {:ok, nil}
        callback when is_function(callback, 0) -> {:ok, callback}
        _ -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp commit_options(_), do: {:error, :invalid_options}
  defp admit(nil), do: :ok

  defp admit(callback) do
    case callback.() do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> {:error, :commit_not_admitted}
    end
  rescue
    _ -> {:error, :commit_not_admitted}
  catch
    _, _ -> {:error, :commit_not_admitted}
  end

  @doc "Page individual Agent directory keys at one owner and committed revision."
  @spec agents_page(keyword(), integer()) :: {:ok, map()} | {:error, term()}
  def agents_page(opts, deadline) do
    with {:ok, limit, cursor} <- page_options(opts),
         {:ok, context, revision, after_key} <- directory_context(cursor, deadline),
         {:ok, records, page} <-
           read_page(context, directory_prefix(), after_key, revision, limit),
         {:ok, agent_ids} <- directory_agents(records),
         {:ok, _remaining} <- check(context) do
      next =
        if page.has_more,
          do: {:standing_intent_agents_cursor, context.owner, revision, page.last_key},
          else: nil

      {:ok, %{agent_ids: agent_ids, next_cursor: next}}
    end
  end

  defp read_generation(context, agent_id, revision) do
    case read_record(context, generation_key(agent_id), revision) do
      {:ok, nil} ->
        {:ok, 0, 0}

      {:ok,
       %Record{
         value: %{schema: 1, kind: :generation, agent_id: ^agent_id, generation: generation},
         mod_revision: mod_revision
       }}
      when is_integer(generation) and generation > 0 ->
        {:ok, generation, mod_revision}

      {:ok, _} ->
        {:error, :invalid_record}

      {:error, _} = error ->
        error
    end
  end

  defp prepare_rows(context, agent_id, revision, rows) do
    Enum.reduce_while(rows, {:ok, [], []}, fn row, {:ok, compares, operations} ->
      id = row["id"]

      with {:ok, record} <- read_record(context, row_key(agent_id, id), revision),
           {:ok, compare} <- row_compare(context, agent_id, revision, row, record) do
        writes = [
          {:put, row_key(agent_id, id),
           %{schema: 1, kind: :row, agent_id: agent_id, payload: row}, %{}},
          {:put, order_key(agent_id, row),
           %{schema: 1, kind: :order, agent_id: agent_id, id: id, created_at: row["createdAt"]},
           %{}}
        ]

        {:cont, {:ok, [compare | compares], operations ++ writes}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp row_compare(context, agent_id, revision, row, nil) do
    case read_value(context, order_key(agent_id, row), revision) do
      {:error, :not_found} -> {:ok, {:exists, row_key(agent_id, row["id"]), :==, false}}
      {:ok, _} -> {:error, :invalid_record}
      {:error, _} = error -> error
    end
  end

  defp row_compare(context, agent_id, revision, row, %Record{} = record) do
    with {:ok, previous} <- payload(record.value, agent_id, row["id"]),
         true <- previous["createdAt"] == row["createdAt"],
         :ok <- verify_order(context, agent_id, previous, revision) do
      {:ok, {:mod_revision, row_key(agent_id, row["id"]), :==, record.mod_revision}}
    else
      false -> {:error, :immutable_created_at}
      error -> error
    end
  end

  defp generation_compare({:standing_intent_snapshot, _, agent_id, _, _, 0}),
    do: {:exists, generation_key(agent_id), :==, false}

  defp generation_compare({:standing_intent_snapshot, _, agent_id, _, _, mod_revision}),
    do: {:mod_revision, generation_key(agent_id), :==, mod_revision}

  defp read_ordered_rows(context, agent_id, revision, records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, rows} ->
      with {:ok, id, created_at} <- order_entry(record, agent_id),
           {:ok, envelope} <- read_value(context, row_key(agent_id, id), revision),
           {:ok, row} <- payload(envelope, agent_id, id),
           true <- row["createdAt"] == created_at do
        {:cont, {:ok, [row | rows]}}
      else
        false -> {:halt, {:error, :invalid_record}}
        {:error, :not_found} -> {:halt, {:error, :invalid_record}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp order_entry(%Record{value: value} = record, agent_id) do
    case value do
      %{schema: 1, kind: :order, agent_id: ^agent_id, id: id, created_at: created_at} ->
        if canonical_id?(id) and valid_time?(created_at) and
             Map.get(record, :key) ==
               order_key(agent_id, %{"id" => id, "createdAt" => created_at}) do
          {:ok, id, created_at}
        else
          {:error, :invalid_record}
        end

      _ ->
        {:error, :invalid_record}
    end
  end

  defp order_entry(_, _), do: {:error, :invalid_record}

  defp verify_order(context, agent_id, row, revision) do
    case read_record(context, order_key(agent_id, row), revision) do
      {:ok, nil} ->
        {:error, :invalid_record}

      {:ok, record} ->
        with {:ok, id, created_at} <- order_entry(record, agent_id),
             true <- id == row["id"] and created_at == row["createdAt"] do
          :ok
        else
          false -> {:error, :invalid_record}
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp payload(%{schema: 1, kind: :row, agent_id: agent_id, payload: row}, agent_id, id) do
    if valid_row?(row) and row["id"] == id,
      do: {:ok, row},
      else: {:error, :invalid_record}
  end

  defp payload(_, _, _), do: {:error, :invalid_record}

  defp validate_rows(rows) when is_list(rows) do
    if Enum.all?(rows, &valid_row?/1) and
         length(rows) == length(Enum.uniq_by(rows, & &1["id"])),
       do: :ok,
       else: {:error, :invalid_rows}
  end

  defp validate_rows(_), do: {:error, :invalid_rows}

  defp valid_row?(%{"id" => id, "createdAt" => created_at}),
    do: canonical_id?(id) and valid_time?(created_at)

  defp valid_row?(_), do: false

  defp valid_time?(time),
    do: is_integer(time) and time >= @minimum_time and time <= @maximum_time

  defp page_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit, :after] == [] do
      limit = Keyword.get(opts, :limit, 64)

      if is_integer(limit) and limit > 0,
        do: {:ok, min(limit, 1_000), Keyword.get(opts, :after)},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp page_options(_), do: {:error, :invalid_options}

  defp order_cursor(nil, _snapshot, _agent_id), do: {:ok, nil}

  defp order_cursor({:standing_intent_cursor, snapshot, key}, snapshot, agent_id) do
    if is_binary(key) and String.starts_with?(key, order_prefix(agent_id)),
      do: {:ok, key},
      else: {:error, :invalid_cursor}
  end

  defp order_cursor(_, _, _), do: {:error, :invalid_cursor}

  defp directory_context(nil, deadline) do
    with {:ok, context} <- capture(deadline),
         {:ok, revision} <- read_revision(context) do
      {:ok, context, revision, nil}
    end
  end

  defp directory_context({:standing_intent_agents_cursor, owner, revision, key}, deadline)
       when is_pid(owner) and is_integer(revision) and revision >= 0 and is_binary(key) do
    with {:ok, _agent_id} <- directory_id(key),
         {:ok, context} <- capture(deadline, owner) do
      {:ok, context, revision, key}
    end
  end

  defp directory_context(_, _), do: {:error, :invalid_cursor}

  defp directory_agents(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, agents} ->
      with %Record{value: %{schema: 1, kind: :agent, agent_id: agent_id}} <- record,
           {:ok, ^agent_id} <- directory_id(Map.get(record, :key)) do
        {:cont, {:ok, [agent_id | agents]}}
      else
        _ -> {:halt, {:error, :invalid_record}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, Enum.reverse(agents)}
      error -> error
    end
  end

  defp directory_id(key) when is_binary(key) do
    prefix = directory_prefix()

    if String.starts_with?(key, prefix) do
      id = binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix))
      if canonical_id?(id), do: {:ok, id}, else: {:error, :invalid_cursor}
    else
      {:error, :invalid_cursor}
    end
  end

  defp directory_id(_), do: {:error, :invalid_cursor}

  defp read_record(context, key, revision) do
    case read(
           context,
           &Concord.Turso.list(
             range: {key, key <> <<0>>},
             revision: revision,
             limit: 1,
             timeout: &1
           )
         ) do
      {:ok, [], %{has_more: false}} ->
        {:ok, nil}

      {:ok, [%Record{mod_revision: mod_revision} = record], %{has_more: false}}
      when is_integer(mod_revision) and mod_revision > 0 and mod_revision <= revision ->
        if Map.get(record, :key) == key, do: {:ok, record}, else: {:error, :invalid_record}

      {:ok, _, _} ->
        {:error, :invalid_record}

      {:error, _} = error ->
        error
    end
  end

  defp read_value(context, key, revision),
    do: read(context, &KV.get(key, engine: :turso, revision: revision, timeout: &1))

  defp read_page(context, prefix, after_key, revision, limit) do
    start = if is_nil(after_key), do: prefix, else: after_key <> <<0>>

    read(
      context,
      &Concord.Turso.list(
        range: {start, prefix <> <<255>>},
        revision: revision,
        limit: limit,
        timeout: &1
      )
    )
  end

  defp read_revision(context) do
    case read(context, &KV.revision(engine: :turso, timeout: &1)) do
      {:ok, revision} when is_integer(revision) and revision >= 0 -> {:ok, revision}
      {:ok, _} -> {:error, :invalid_record}
      {:error, _} = error -> error
    end
  end

  defp snapshot_context(
         {:standing_intent_snapshot, owner, agent_id, revision, generation, mod_revision},
         deadline
       )
       when is_pid(owner) and is_integer(revision) and revision >= 0 and
              is_integer(generation) and generation >= 0 and is_integer(mod_revision) and
              mod_revision >= 0 and mod_revision <= revision do
    with true <- canonical_id?(agent_id),
         {:ok, context} <- capture(deadline, owner) do
      {:ok, context, agent_id, revision}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp snapshot_context(_, _), do: {:error, :invalid_snapshot}

  defp capture(deadline, expected_owner \\ nil)

  defp capture(deadline, expected_owner) when is_integer(deadline) do
    now = System.monotonic_time(:millisecond)
    config = Application.get_env(:concord, :turso, [])
    database = Keyword.get(config, :database)
    owner = Process.whereis(Concord.Turso.DB)

    cond do
      deadline <= now ->
        {:error, :timeout}

      not is_nil(expected_owner) and owner != expected_owner ->
        {:error, :owner_changed}

      Keyword.get(config, :enabled, false) and is_binary(database) and database != "" and
        database != ":memory:" and
        not String.starts_with?(database, ["file:", "libsql:", "http:", "https:"]) and
        is_nil(Keyword.get(config, :remote_url)) and is_pid(owner) and node(owner) == node() ->
        {:ok, %{owner: owner, deadline: min(deadline, now + @maximum_timeout)}}

      true ->
        {:error, :storage_unavailable}
    end
  end

  defp capture(_, _), do: {:error, :invalid_deadline}

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

  defp transact(context, spec) do
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
  defp agent_prefix(agent_id), do: @prefix <> "agents/" <> agent_id <> "/"
  defp row_key(agent_id, id), do: agent_prefix(agent_id) <> "rows/" <> id
  defp generation_key(agent_id), do: agent_prefix(agent_id) <> "generation"
  defp order_prefix(agent_id), do: agent_prefix(agent_id) <> "order/"
  defp directory_prefix, do: @prefix <> "directory/"
  defp directory_key(agent_id), do: directory_prefix() <> agent_id

  defp order_key(agent_id, row) do
    timestamp =
      (row["createdAt"] + @time_offset)
      |> Integer.to_string(16)
      |> String.pad_leading(16, "0")

    order_prefix(agent_id) <> timestamp <> "/" <> row["id"]
  end
end
