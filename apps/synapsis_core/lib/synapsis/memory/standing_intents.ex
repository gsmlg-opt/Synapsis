defmodule Synapsis.Memory.StandingIntents do
  @moduledoc """
  Standing-intent create, list, cancel and sweep over Data-owned Concord rows.

  The existing Memory.Writer owns a FIFO lane per Agent and delegates storage
  work to its existing task supervisor. Callers supply a shared absolute deadline
  and a bounded liveness callback. Creation receives prepared domain values,
  rather than raw tool arguments. Search and model-facing tools are not exposed.

  Results contain the public `value` and an internal `next_due_at`: nil means
  lifecycle knowledge was invalidated; :infinity means observed absence of an
  active deadline. This module does not schedule maintenance or cache absence.
  """

  alias Synapsis.Memory.StandingIntent.Store
  alias Synapsis.Memory.StandingIntents.Model
  alias Synapsis.Memory.Writer

  @statuses ~w(pending armed fired done cancelled expired)
  @integer_fields ~w(expiresAt maxFires fireCount cooldownSeconds createdAt)
  @nullable_strings ~w(triggerEmbedding channelScope senderScope creatorSender sourceSessionId)
  @fields @integer_fields ++
            @nullable_strings ++ ~w(id description triggerKeywords status lastFiredAt)

  @doc "Create from prepared values; capture the UUID and creation time before queueing."
  def create(agent_id, prepared, execution) do
    with {:ok, context} <- context(agent_id, execution),
         :ok <- check(context),
         {:ok, row} <- Model.new_row(Ecto.UUID.generate(), prepared, now(context)) do
      request({:create, row}, context)
    end
  end

  @doc "Maintain the full inventory, then return all rows selected by optional status."
  def list(agent_id, opts, execution) do
    with {:ok, context} <- context(agent_id, execution),
         {:ok, status} <- list_status(opts) do
      request({:list, status}, context)
    end
  end

  @doc "Maintain the full inventory without returning public rows."
  def sweep(agent_id, execution) do
    with {:ok, context} <- context(agent_id, execution), do: request(:sweep, context)
  end

  @doc "Cancel only the requested active row; do not implicitly sweep its expiry."
  def cancel(agent_id, id, execution) when is_binary(id) do
    with {:ok, context} <- context(agent_id, execution),
         do: request({:cancel, id}, context)
  end

  def cancel(_, _, _), do: {:error, :invalid_intent_id}

  @doc false
  def perform(command, context) do
    with :ok <- check(context),
         {:ok, snapshot} <- Store.snapshot(context.agent_id, context.deadline) do
      execute(command, context, snapshot)
    end
  end

  defp execute({:create, row}, context, snapshot) do
    case Store.get(snapshot, row["id"], context.deadline) do
      {:error, :not_found} ->
        with {:ok, _} <- commit(snapshot, [row], context),
             do: result(Model.to_intent(row), nil)

      {:ok, _} ->
        {:error, :resource_conflict}

      {:error, _} = error ->
        error
    end
  end

  defp execute({:cancel, id}, context, snapshot) do
    found =
      case Ecto.UUID.cast(id) do
        {:ok, ^id} -> Store.get(snapshot, id, context.deadline)
        _ -> {:error, :not_found}
      end

    case found do
      {:ok, row} ->
        with :ok <- validate_row(row) do
          case Model.cancel(row) do
            nil ->
              with :ok <- unchanged(snapshot, context), do: result(nil, nil)

            cancelled ->
              with {:ok, _} <- commit(snapshot, [cancelled], context),
                   do: result(Model.to_intent(cancelled), nil)
          end
        end

      {:error, :not_found} ->
        with :ok <- unchanged(snapshot, context), do: result(nil, nil)

      {:error, _} = error ->
        error
    end
  end

  defp execute(command, context, snapshot) do
    # Source list/sweep resolve a default clock inside the executing operation.
    observed_at = now(context)

    with {:ok, rows} <- read_all(snapshot, context, nil, []),
         :ok <- validate_rows(rows) do
      maintained = Enum.map(rows, &Model.maintain(&1, observed_at))

      changes =
        Enum.zip(rows, maintained)
        |> Enum.flat_map(fn {before, after_row} ->
          if before == after_row, do: [], else: [after_row]
        end)

      with :ok <- persist_changes(snapshot, changes, context) do
        value =
          case command do
            :sweep ->
              nil

            {:list, status} ->
              maintained
              |> Enum.filter(&(is_nil(status) or &1["status"] == status))
              |> Enum.map(&Model.to_intent/1)
          end

        result(value, Model.next_due(maintained))
      end
    end
  end

  defp read_all(snapshot, context, cursor, pages) do
    with :ok <- check(context),
         {:ok, page} <- Store.list_page(snapshot, [after: cursor], context.deadline) do
      pages = [page.rows | pages]

      case page.next_cursor do
        nil -> {:ok, pages |> Enum.reverse() |> List.flatten()}
        next -> read_all(snapshot, context, next, pages)
      end
    end
  end

  defp persist_changes(snapshot, [], context), do: unchanged(snapshot, context)

  defp persist_changes(snapshot, changes, context) do
    # Never split an atomic lifecycle operation to fit the storage envelope.
    with {:ok, _} <- commit(snapshot, changes, context), do: :ok
  end

  defp commit(snapshot, rows, context) do
    with :ok <- check(context) do
      Store.commit(snapshot, rows, context.deadline, before_commit: fn -> check(context) end)
    end
  end

  defp unchanged(snapshot, context) do
    with :ok <- check(context),
         {:ok, current} <- Store.snapshot(context.agent_id, context.deadline),
         true <- Store.generation(current) == Store.generation(snapshot),
         :ok <- check(context),
         # Use the public API to check the original opaque snapshot's owner.
         {:ok, _} <- Store.list_page(snapshot, [limit: 1], context.deadline) do
      :ok
    else
      false -> {:error, :resource_conflict}
      error -> error
    end
  end

  defp context(agent_id, execution) when is_map(execution) do
    with {:ok, ^agent_id} <- Ecto.UUID.cast(agent_id),
         deadline when is_integer(deadline) <- execution[:deadline],
         live when is_function(live, 0) <- execution[:assert_live],
         true <- is_nil(execution[:now_ms]) or is_integer(execution[:now_ms]) do
      {:ok,
       %{
         agent_id: agent_id,
         caller: self(),
         deadline: min(deadline, System.monotonic_time(:millisecond) + 5_000),
         assert_live: live,
         now_ms: execution[:now_ms]
       }}
    else
      _ -> {:error, :invalid_execution}
    end
  end

  defp context(_, _), do: {:error, :invalid_execution}

  defp request(command, context) do
    with :ok <- check(context) do
      timeout = max(1, context.deadline - System.monotonic_time(:millisecond)) + 1_000
      GenServer.call(Writer, {:standing_intent, command, context}, timeout)
    end
  catch
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, {:timeout, _} -> {:error, {:unknown_outcome, :timeout}}
    :exit, _ -> {:error, {:unknown_outcome, :owner_exit}}
  end

  defp check(context) do
    cond do
      context.deadline <= System.monotonic_time(:millisecond) ->
        {:error, :timeout}

      not Process.alive?(context.caller) ->
        {:error, :caller_closed}

      not is_nil(context[:owner]) and Process.whereis(Writer) != context.owner ->
        {:error, :owner_changed}

      true ->
        case context.assert_live.() do
          :ok -> :ok
          {:error, _} = error -> error
          _ -> {:error, :not_current}
        end
    end
  rescue
    _ -> {:error, :not_current}
  catch
    _, _ -> {:error, :not_current}
  end

  defp list_status(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:status] == [] and
         (is_nil(opts[:status]) or opts[:status] in @statuses),
       do: {:ok, opts[:status]},
       else: {:error, :invalid_options}
  end

  defp list_status(_), do: {:error, :invalid_options}

  defp validate_rows(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case validate_row(row) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_row(row) do
    if Enum.all?(@fields, &Map.has_key?(row, &1)) and
         is_binary(row["description"]) and is_binary(row["triggerKeywords"]) and
         row["status"] in @statuses and
         Enum.all?(@integer_fields, &is_integer(row[&1])) and
         Enum.all?(@nullable_strings, &(is_nil(row[&1]) or is_binary(row[&1]))) and
         (is_nil(row["lastFiredAt"]) or is_integer(row["lastFiredAt"])),
       do: :ok,
       else: {:error, :invalid_intent_record}
  end

  defp now(%{now_ms: now}) when is_integer(now), do: now
  defp now(_), do: System.system_time(:millisecond)
  defp result(value, due), do: {:ok, %{value: value, next_due_at: due}}
end
