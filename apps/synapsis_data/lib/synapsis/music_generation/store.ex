defmodule Synapsis.MusicGeneration.Store do
  @moduledoc """
  Durable music-task records in the existing embedded Concord owner.

  Callers supply complete portable request, origin, result, status and activity
  facts. This data boundary does not select a provider, run generation, decide
  duplicate-request policy or deliver a completion. It never executes callbacks.
  Credentials, native callbacks and process handles are not part of its record.

  Creation starts at record revision one and atomically publishes the task,
  its exact submission lookup and an optional active mirror. Updates compare
  the actual record's storage revision,
  preserve original submission/request/provenance and atomically maintain that
  mirror. The submission lookup survives completion; reading it is not a retry.

  Pages are current-state UUID order, with a maximum of 100 records. They do not
  promise a snapshot across pages or source task-selection ordering. Each call
  shares the caller's absolute monotonic deadline, capped at five seconds. A
  known transaction acknowledgement is retained after the deadline; uncertain
  dispatched writes are reported without retry or rollback.

  `snapshot/3` instead captures one committed revision and retains it across
  every historical page. It returns all jobs in immutable creation-revision
  order while preserving the existing receipts, without an additional owner,
  schema field or ordinal index. It does not select source task lifetime or
  interpret current durable records as process-owned OpenClaw operations.
  """

  alias Concord.KV
  alias Concord.KV.Record

  @prefix "coord/music-generation/v1/"
  @timeout 5_000
  @fields ~w(schema_version id session_id agent_id revision status active submission_id request_key request origin result created_at updated_at)a
  @immutable @fields -- ~w(revision status active result updated_at)a
  @digest ~r/\A[a-f0-9]{64}\z/

  def create(record, deadline) do
    with true <- valid?(record) and record.revision == 1,
         {:ok, context} <- capture(deadline),
         key = job_key(record),
         submission = submission_key(record.session_id, record.agent_id, record.submission_id),
         active = active_key(record),
         compares = Enum.map([key, submission, active], &{:exists, &1, :==, false}),
         puts = [put(key, record), put(submission, record.id)] ++ active_puts(record),
         {:ok, revision} <- transact(context, compares, puts) do
      {:ok, row(record, revision)}
    else
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  def get(session_id, agent_id, id, deadline) do
    with true <- scope?(session_id, agent_id) and uuid?(id),
         {:ok, context} <- capture(deadline) do
      read_job(context, session_id, agent_id, id)
    else
      false -> {:error, :invalid_identity}
      error -> error
    end
  end

  def find_submission(session_id, agent_id, submission_id, deadline) do
    with true <- scope?(session_id, agent_id) and text?(submission_id),
         {:ok, context} <- capture(deadline),
         {:ok, %Record{value: id}} <-
           read_record(context, submission_key(session_id, agent_id, submission_id)),
         true <- uuid?(id),
         {:ok, %{record: record} = result} <- read_job(context, session_id, agent_id, id),
         true <- record.submission_id == submission_id do
      {:ok, result}
    else
      false -> {:error, :invalid_submission}
      error -> error
    end
  end

  def replace(%{record: previous, storage_revision: expected} = receipt, record, deadline)
      when map_size(receipt) == 2 do
    with true <- valid?(previous) and valid?(record) and is_integer(expected) and expected > 0,
         true <- Map.take(record, @immutable) === Map.take(previous, @immutable),
         true <- record.revision == previous.revision + 1,
         {:ok, context} <- capture(deadline),
         {:ok, ^receipt} <-
           read_job(context, previous.session_id, previous.agent_id, previous.id),
         {:ok, active_compare} <- active_compare(context, receipt),
         puts = [put(job_key(record), record)] ++ active_update(record),
         {:ok, revision} <-
           transact(
             context,
             [{:mod_revision, job_key(record), :==, expected}, active_compare],
             puts
           ) do
      {:ok, row(record, revision)}
    else
      false -> {:error, :invalid_transition}
      {:ok, _different} -> {:error, :resource_conflict}
      error -> error
    end
  end

  def replace(_, _, _), do: {:error, :invalid_transition}

  def page(session_id, agent_id, view, opts, deadline) do
    with true <- scope?(session_id, agent_id) and view in [:all, :active],
         {:ok, limit, cursor} <- page_options(opts),
         {:ok, after_id} <- cursor_id(cursor, session_id, agent_id, view),
         {:ok, context} <- capture(deadline),
         prefix = page_prefix(session_id, agent_id, view),
         start = if(is_nil(after_id), do: prefix, else: prefix <> after_id <> <<0>>),
         {:ok, records, metadata} <-
           read(context, fn timeout ->
             Concord.Turso.list(
               range: {start, prefix <> "\u{10FFFF}"},
               limit: limit,
               keys_only: false,
               queue: true,
               timeout: timeout
             )
           end),
         {:ok, rows} <- page_rows(records, session_id, agent_id, view),
         {:ok, cursor} <- next_cursor(metadata, rows, session_id, agent_id, view) do
      {:ok, %{rows: rows, next_cursor: cursor}}
    else
      false -> {:error, :invalid_scope}
      error -> error
    end
  end

  @doc """
  Reads all durable tasks at one captured revision, in original admission order.

  Each historical page retains the same committed revision and full Record
  metadata. Sorting uses immutable create_revision, rather than UUID order or
  later replacement revisions. Receipts keep their existing two-key shape.
  One shared local owner and capped absolute deadline cover the entire read;
  no truncated or partially read snapshot is returned.

  This is a data snapshot, not a source activity owner: callers still determine
  owner generation, task lifetime and source-field mapping before status use.
  Music records have no TTL; Concord's historical TTL visibility and database
  replacement/retention limits still apply to its general snapshot facility.
  """
  def snapshot(session_id, agent_id, deadline) do
    with true <- scope?(session_id, agent_id),
         {:ok, context} <- capture(deadline),
         {:ok, revision} <- read(context, &Concord.Turso.revision(timeout: &1)),
         true <- is_integer(revision) and revision >= 0,
         prefix = jobs_prefix(session_id, agent_id),
         {:ok, entries} <-
           snapshot_pages(context, session_id, agent_id, revision, prefix, []) do
      rows = entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
      with {:ok, _timeout} <- remaining(context), do: {:ok, %{revision: revision, rows: rows}}
    else
      false -> {:error, :invalid_scope}
      error -> error
    end
  end

  defp snapshot_pages(context, session_id, agent_id, revision, start, acc) do
    prefix = jobs_prefix(session_id, agent_id)

    with {:ok, records, metadata} <-
           read(context, fn timeout ->
             Concord.Turso.list(
               range: {start, prefix <> "\u{10FFFF}"},
               revision: revision,
               limit: 100,
               keys_only: false,
               queue: true,
               timeout: timeout
             )
           end),
         {:ok, rows} <- page_rows(records, session_id, agent_id, :all),
         true <-
           Enum.all?(records, fn stored ->
             is_integer(stored.create_revision) and stored.create_revision > 0 and
               stored.create_revision <= stored.mod_revision and stored.mod_revision <= revision
           end) do
      entries = Enum.zip_with(records, rows, &{&1.create_revision, &2})
      acc = Enum.reverse(entries, acc)
      snapshot_continue(context, session_id, agent_id, revision, start, records, metadata, acc)
    else
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  defp snapshot_continue(_, _, _, _, _, _, %{has_more: false}, acc), do: {:ok, acc}

  defp snapshot_continue(
         context,
         session_id,
         agent_id,
         revision,
         start,
         [_ | _] = records,
         %{has_more: true, last_key: key},
         acc
       ) do
    if is_binary(key) and key >= start and Map.get(List.last(records), :key) == key do
      snapshot_pages(context, session_id, agent_id, revision, key <> <<0>>, acc)
    else
      {:error, :invalid_page}
    end
  end

  defp snapshot_continue(_, _, _, _, _, _, _, _), do: {:error, :invalid_page}

  defp page_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit, :cursor] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      limit = Keyword.get(opts, :limit, 50)

      if is_integer(limit) and limit > 0,
        do: {:ok, min(limit, 100), Keyword.get(opts, :cursor)},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp page_options(_), do: {:error, :invalid_options}
  defp cursor_id(nil, _, _, _), do: {:ok, nil}

  defp cursor_id({:music_task_cursor, session_id, agent_id, view, id}, session_id, agent_id, view) do
    if uuid?(id), do: {:ok, id}, else: {:error, :invalid_cursor}
  end

  defp cursor_id(_, _, _, _), do: {:error, :invalid_cursor}

  defp next_cursor(%{has_more: false}, _, _, _, _), do: {:ok, nil}

  defp next_cursor(%{has_more: true}, [_ | _] = rows, session_id, agent_id, view) do
    {:ok, {:music_task_cursor, session_id, agent_id, view, List.last(rows).record.id}}
  end

  defp next_cursor(_, _, _, _, _), do: {:error, :invalid_page}

  defp page_rows(records, session_id, agent_id, view) when is_list(records) do
    Enum.reduce_while(records, {:ok, []}, fn
      %Record{value: value, mod_revision: revision} = stored, {:ok, rows} ->
        if valid?(value) and value.session_id == session_id and value.agent_id == agent_id and
             (view == :all or value.active) and
             Map.get(stored, :key) == page_prefix(session_id, agent_id, view) <> value.id and
             is_integer(revision) and revision > 0 do
          {:cont, {:ok, [row(value, revision) | rows]}}
        else
          {:halt, {:error, :invalid_record}}
        end

      _, _ ->
        {:halt, {:error, :invalid_record}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp page_rows(_, _, _, _), do: {:error, :invalid_page}

  defp active_compare(context, %{record: previous, storage_revision: expected}) do
    case read_record(context, active_key(previous)) do
      :not_found when not previous.active ->
        {:ok, {:exists, active_key(previous), :==, false}}

      {:ok, %Record{value: ^previous, mod_revision: ^expected}} when previous.active ->
        {:ok, {:mod_revision, active_key(previous), :==, expected}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :resource_conflict}
    end
  end

  defp read_job(context, session_id, agent_id, id) do
    with {:ok, %Record{value: value, mod_revision: revision}} <-
           read_record(context, jobs_prefix(session_id, agent_id) <> id),
         true <-
           valid?(value) and value.session_id == session_id and value.agent_id == agent_id and
             value.id == id and is_integer(revision) and revision > 0 do
      {:ok, row(value, revision)}
    else
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  defp read_record(context, key) do
    case read(context, &KV.get(key, engine: :turso, metadata: true, timeout: &1)) do
      {:error, :not_found} -> :not_found
      other -> other
    end
  end

  defp valid?(value) when is_map(value) and not is_struct(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@fields) and value.schema_version === 1 and
      scope?(value.session_id, value.agent_id) and uuid?(value.id) and
      is_integer(value.revision) and value.revision > 0 and text?(value.status) and
      is_boolean(value.active) and text?(value.submission_id) and
      is_binary(value.request_key) and Regex.match?(@digest, value.request_key) and
      json_map?(value.request) and json_map?(value.origin) and
      (is_nil(value.result) or json_map?(value.result)) and
      is_integer(value.created_at) and value.created_at >= 0 and
      is_integer(value.updated_at) and value.updated_at >= 0
  end

  defp valid?(_), do: false
  defp json_map?(value), do: is_map(value) and not is_struct(value) and json?(value)

  defp json?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, val} -> is_binary(key) and String.valid?(key) and json?(val) end)

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)
  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
  defp scope?(session_id, agent_id), do: uuid?(session_id) and uuid?(agent_id)
  defp uuid?(value) when is_binary(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp uuid?(_), do: false
  defp row(record, revision), do: %{record: record, storage_revision: revision}
  defp put(key, value), do: {:put, key, value, %{}}
  defp active_puts(%{active: true} = record), do: [put(active_key(record), record)]
  defp active_puts(_), do: []
  defp active_update(%{active: true} = record), do: active_puts(record)
  defp active_update(record), do: [{:delete, {:key, active_key(record)}, %{}}]

  defp scope_prefix(session_id, agent_id), do: @prefix <> session_id <> "/" <> agent_id <> "/"
  defp jobs_prefix(session_id, agent_id), do: scope_prefix(session_id, agent_id) <> "jobs/"
  defp page_prefix(session_id, agent_id, :all), do: jobs_prefix(session_id, agent_id)

  defp page_prefix(session_id, agent_id, :active),
    do: scope_prefix(session_id, agent_id) <> "active/"

  defp job_key(record), do: jobs_prefix(record.session_id, record.agent_id) <> record.id

  defp active_key(record),
    do: page_prefix(record.session_id, record.agent_id, :active) <> record.id

  defp submission_key(session_id, agent_id, submission_id),
    do:
      scope_prefix(session_id, agent_id) <>
        "submissions/" <> Base.url_encode64(submission_id, padding: false)

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
        {:ok, %{owner: owner, deadline: min(deadline, now + @timeout)}}

      true ->
        {:error, :storage_unavailable}
    end
  end

  defp capture(_), do: {:error, :invalid_deadline}

  defp remaining(context) do
    timeout = context.deadline - System.monotonic_time(:millisecond)

    cond do
      Process.whereis(Concord.Turso.DB) != context.owner -> {:error, :owner_changed}
      timeout <= 0 -> {:error, :timeout}
      true -> {:ok, timeout}
    end
  end

  defp read(context, operation) do
    with {:ok, timeout} <- remaining(context) do
      result = invoke(operation, timeout)
      with {:ok, _} <- remaining(context), do: result
    end
  end

  defp transact(context, compares, puts) do
    with {:ok, timeout} <- remaining(context) do
      spec = %{compare: compares, success: puts, failure: []}

      case invoke(&Concord.Turso.txn(spec, timeout: &1), timeout) do
        {:ok, %{succeeded: true, revision: revision}}
        when is_integer(revision) and revision > 0 ->
          {:ok, revision}

        {:ok, %{succeeded: false}} ->
          {:error, :resource_conflict}

        {:error, reason} ->
          {:error, {:unknown_outcome, reason}}

        _ ->
          {:error, {:unknown_outcome, :invalid_transaction_result}}
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
end
