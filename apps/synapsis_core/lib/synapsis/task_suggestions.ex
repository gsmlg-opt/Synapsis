defmodule Synapsis.TaskSuggestions do
  @moduledoc """
  Process-local follow-up proposals. Recording a suggestion never starts work.

  The supervised registry retains at most 100 records and 2 MiB of suggestion
  JSON, including list delimiters. Dismissed records are evicted first, then
  oldest accepted and pending records. In-flight and uncertain launches remain
  protected. There is no TTL or durable suggestion storage. A service restart
  loses all suggestions and retained acceptance receipts.

  `list/2` returns pending suggestion records for one exact source session,
  newest first. `get/3` exposes a retained lifecycle record to its source owner.
  Calls share a deadline of at most five seconds. A mutation whose reply is lost
  returns `:unknown_outcome`; callers must not automatically retry creates.
  """
  use GenServer

  @max_count 100
  @max_bytes 2 * 1024 * 1024
  @budget 5_000
  @acceptance_budget 30_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, nil)
      name -> GenServer.start_link(__MODULE__, nil, name: name)
    end
  end

  def create(input, context, opts \\ []) do
    with {:ok, server, deadline} <- call_options(opts),
         {:ok, candidate} <- prepare(:create, input, context),
         do: request({:create, candidate}, server, deadline, true)
  end

  def dismiss(input, context, opts \\ []) do
    with {:ok, server, deadline} <- call_options(opts),
         {:ok, target} <- prepare(:dismiss, input, context),
         do: request({:dismiss, target}, server, deadline, true)
  end

  def list(context, opts \\ []) do
    with {:ok, server, deadline} <- call_options(opts),
         :ok <- source_valid(context),
         do: request({:list, context.session_id}, server, deadline, false)
  end

  @doc "Retained host lifecycle rows for the exact source session."
  def list_for_host(context, opts \\ []) do
    with {:ok, server, deadline} <- call_options(opts),
         :ok <- source_valid(context),
         do: request({:list_for_host, context.session_id}, server, deadline, false)
  end

  @doc "Claim one retained proposal for a new local session. Replays retain its identity."
  def accept(task_id, context, opts \\ []) do
    with {:ok, server, deadline} <- call_options(opts),
         :ok <- source_valid(context),
         true <- text?(task_id, 1, 128) and text?(context[:requester_id], 1, 256) do
      request({:accept, task_id, context}, server, deadline, true)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def get(task_id, context, opts \\ []) do
    with {:ok, server, deadline} <- call_options(opts),
         :ok <- owner_valid(context),
         true <- text?(task_id, 1, 128) do
      request(
        {:get, task_id, Map.take(context, [:session_id, :agent_id])},
        server,
        deadline,
        false
      )
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Pure input normalization for native classification and execution."
  def prepare(:create, input, context) when is_map(input) and not is_struct(input) do
    with :ok <- owner_valid(context),
         true <- Map.keys(input) -- ~w(title prompt tldr cwd) == [],
         {:ok, title} <- required(input, "title", 60),
         {:ok, prompt} <- required(input, "prompt", 32_768),
         {:ok, tldr} <- required(input, "tldr", 1_024),
         true <-
           not Map.has_key?(input, "cwd") or
             (is_binary(input["cwd"]) and String.valid?(input["cwd"])),
         cwd = optional_trim(input["cwd"]) || context[:cwd],
         true <- absolute?(cwd) do
      {:ok,
       %{
         title: title,
         prompt: prompt,
         tldr: tldr,
         cwd: cwd,
         session_id: context.session_id,
         agent_id: context.agent_id
       }}
    else
      {:error, :invalid_context} = error -> error
      _ -> {:error, :invalid_input}
    end
  end

  def prepare(:dismiss, input, context) when is_map(input) and not is_struct(input) do
    with :ok <- owner_valid(context),
         true <- Map.keys(input) -- ~w(task_id reason) == [],
         {:ok, id} <- required(input, "task_id", 128),
         true <- not Map.has_key?(input, "reason") or text?(input["reason"], 0, 1_024) do
      {:ok, %{task_id: id, session_id: context.session_id, agent_id: context.agent_id}}
    else
      {:error, :invalid_context} = error -> error
      _ -> {:error, :invalid_input}
    end
  end

  def prepare(_, _, _), do: {:error, :invalid_input}

  @impl true
  def init(_), do: {:ok, %{records: [], bytes: 0, tasks: %{}}}

  @impl true
  def handle_call({operation, deadline}, _from, state) do
    if now() < deadline,
      do: apply_operation(operation, deadline, state),
      else: {:reply, {:error, :timeout}, state}
  end

  defp apply_operation({:create, candidate}, deadline, state) do
    suggestion =
      Map.merge(candidate, %{
        id: "task_" <> Ecto.UUID.generate(),
        created_at: System.system_time(:millisecond)
      })

    bytes = byte_size(Jason.encode!(suggestion)) + 1

    case plan_evictions(state, bytes) do
      {:ok, evicted, kept, kept_bytes} ->
        if now() < deadline do
          record = %{status: "pending", suggestion: suggestion, bytes: bytes}
          next = %{state | records: kept ++ [record], bytes: kept_bytes + bytes}
          # Commit the complete admission plan before publishing any observation.
          {:reply, {:ok, %{task_id: suggestion.id}}, next,
           {:continue, {:created, evicted, suggestion}}}
        else
          {:reply, {:error, :timeout}, state}
        end

      :full ->
        {:reply, {:error, :capacity}, state}
    end
  end

  defp apply_operation({:dismiss, target}, _deadline, state) do
    {records, dismissed} =
      Enum.map_reduce(state.records, false, fn record, changed ->
        if record.status == "pending" and record.suggestion.id == target.task_id and
             owned?(record.suggestion, target),
           do: {%{record | status: "dismissed"}, true},
           else: {record, changed}
      end)

    next = %{state | records: records}
    reply = {:ok, %{task_id: target.task_id, dismissed: dismissed}}

    if dismissed,
      do: {:reply, reply, next, {:continue, {:dismissed, target}}},
      else: {:reply, reply, next}
  end

  defp apply_operation({:list, session_id}, _deadline, state) do
    rows =
      for record <- Enum.reverse(state.records),
          record.status == "pending" and record.suggestion.session_id == session_id,
          do: record.suggestion

    {:reply, {:ok, rows}, state}
  end

  defp apply_operation({:get, id, owner}, _deadline, state) do
    result =
      case Enum.find(state.records, &(&1.suggestion.id == id and owned?(&1.suggestion, owner))) do
        nil -> {:error, :not_found}
        record -> {:ok, host_row(record)}
      end

    {:reply, result, state}
  end

  defp apply_operation({:list_for_host, session_id}, _deadline, state) do
    rows =
      for record <- Enum.reverse(state.records),
          record.status in ["pending", "accepting", "accepted", "unknown_outcome"] and
            record.suggestion.session_id == session_id,
          do: host_row(record)

    {:reply, {:ok, rows}, state}
  end

  defp apply_operation({:accept, id, context}, _deadline, state) do
    case Enum.find(state.records, fn record ->
           record.suggestion.id == id and record.suggestion.session_id == context.session_id
         end) do
      %{status: "pending"} = record ->
        claimed =
          Map.merge(record, %{
            status: "accepting",
            session_id: Ecto.UUID.generate(),
            claim_id: Ecto.UUID.generate(),
            receipt: nil,
            acceptance_deadline: now() + @acceptance_budget
          })

        next = replace_record(state, claimed)

        {:reply, {:ok, claim_receipt(claimed)}, next,
         {:continue, {:accept, claimed, context.requester_id}}}

      %{status: status} = record when status in ["accepting", "accepted", "unknown_outcome"] ->
        {:reply, {:ok, claim_receipt(record)}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {claim, tasks} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(claim.timer)
        finish_claim(%{state | tasks: tasks}, claim, result)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {claim, tasks} ->
        Process.cancel_timer(claim.timer)
        finish_claim(%{state | tasks: tasks}, claim, {:error, :unknown_outcome})
    end
  end

  def handle_info({:acceptance_expired, claim}, state),
    do: finish_claim(state, claim, {:error, :unknown_outcome})

  @impl true
  def handle_continue({:accept, record, requester_id}, state) do
    publish_change(record)

    claim = %{
      task_id: record.suggestion.id,
      claim_id: record.claim_id,
      session_id: record.session_id
    }

    try do
      task =
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          Synapsis.TaskSuggestions.Acceptance.run(
            record.suggestion,
            record.session_id,
            requester_id,
            record.claim_id,
            record.acceptance_deadline
          )
        end)

      timer =
        Process.send_after(
          self(),
          {:acceptance_expired, claim},
          max(record.acceptance_deadline - now(), 0)
        )

      {:noreply, %{state | tasks: Map.put(state.tasks, task.ref, Map.put(claim, :timer, timer))}}
    catch
      :exit, _ -> finish_claim(state, claim, {:error, :unknown_outcome})
    end
  end

  def handle_continue({:created, evicted, suggestion}, state) do
    for %{status: "pending", suggestion: expired} <- evicted do
      publish(
        expired.session_id,
        {:task_suggestion_resolved, %{task_id: expired.id, status: "expired"}}
      )
    end

    publish(suggestion.session_id, {:task_suggestion_created, suggestion})
    {:noreply, state}
  end

  def handle_continue({:dismissed, target}, state) do
    publish(
      target.session_id,
      {:task_suggestion_resolved, %{task_id: target.task_id, status: "dismissed"}}
    )

    {:noreply, state}
  end

  def handle_continue({:claim_finished, %{status: "accepted"} = record}, state) do
    publish(record.suggestion.session_id, {:task_suggestion_resolved, record.receipt})
    {:noreply, state}
  end

  def handle_continue({:claim_finished, record}, state) do
    publish_change(record)
    {:noreply, state}
  end

  defp plan_evictions(state, bytes) do
    candidates =
      Enum.filter(state.records, &(&1.status == "dismissed")) ++
        Enum.filter(state.records, &(&1.status == "accepted")) ++
        Enum.filter(state.records, &(&1.status == "pending"))

    plan(candidates, state.records, [], state.bytes, bytes)
  end

  defp plan(_candidates, kept, evicted, kept_bytes, bytes)
       when length(kept) + 1 <= @max_count and kept_bytes + bytes + 1 <= @max_bytes,
       do: {:ok, Enum.reverse(evicted), kept, kept_bytes}

  defp plan([record | rest], kept, evicted, kept_bytes, bytes),
    do:
      plan(rest, List.delete(kept, record), [record | evicted], kept_bytes - record.bytes, bytes)

  defp plan([], _kept, _evicted, _kept_bytes, _bytes), do: :full

  defp finish_claim(state, claim, result) do
    record =
      Enum.find(state.records, fn record ->
        record.suggestion.id == claim.task_id and record[:claim_id] == claim.claim_id and
          record[:session_id] == claim.session_id and
          record.status in ["accepting", "unknown_outcome"]
      end)

    case record do
      nil ->
        {:noreply, state}

      record ->
        next_record =
          case result do
            {:ok, %{status: "accepted"} = receipt} ->
              %{record | status: "accepted", receipt: receipt}

            {:error, {:pre_effect, _}} ->
              record
              |> Map.drop([:session_id, :claim_id, :receipt, :acceptance_deadline])
              |> Map.put(:status, "pending")

            _ ->
              %{record | status: "unknown_outcome"}
          end

        next = replace_record(state, next_record)
        {:noreply, next, {:continue, {:claim_finished, next_record}}}
    end
  end

  defp replace_record(state, updated) do
    %{
      state
      | records:
          Enum.map(state.records, fn record ->
            if record.suggestion.id == updated.suggestion.id, do: updated, else: record
          end)
    }
  end

  defp host_row(record) do
    %{
      status: record.status,
      suggestion: record.suggestion,
      receipt: record[:receipt],
      session_id: record[:session_id],
      task_id: record.suggestion.id
    }
  end

  defp claim_receipt(%{status: "accepted", receipt: receipt}), do: receipt

  defp claim_receipt(record),
    do: %{status: record.status, task_id: record.suggestion.id, session_id: record.session_id}

  defp publish_change(record),
    do:
      publish(
        record.suggestion.session_id,
        {:task_suggestion_changed,
         %{
           task_id: record.suggestion.id,
           status: record.status,
           session_id: record[:session_id]
         }}
      )

  defp request(operation, server, deadline, mutation?) do
    case deadline - now() do
      remaining when remaining > 0 ->
        try do
          result = GenServer.call(server, {operation, deadline}, remaining)

          if now() < deadline,
            do: result,
            else:
              {:error,
               if(mutation? and match?({:ok, _}, result), do: :unknown_outcome, else: :timeout)}
        catch
          :exit, {:noproc, _} -> {:error, :unavailable}
          :exit, _ -> {:error, if(mutation?, do: :unknown_outcome, else: :timeout)}
        end

      _ ->
        {:error, :timeout}
    end
  end

  defp call_options(opts) when is_list(opts) do
    ceiling = now() + @budget

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:server, :deadline] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         is_integer(Keyword.get(opts, :deadline, ceiling)),
       do:
         {:ok, Keyword.get(opts, :server, __MODULE__),
          min(Keyword.get(opts, :deadline, ceiling), ceiling)},
       else: {:error, :invalid_input}
  end

  defp call_options(_), do: {:error, :invalid_input}

  defp source_valid(context) when is_map(context) and not is_struct(context) do
    if is_binary(context[:session_id]) and
         match?({:ok, _}, Ecto.UUID.cast(context.session_id)),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp source_valid(_), do: {:error, :invalid_context}

  defp owner_valid(context) do
    with :ok <- source_valid(context),
         true <- text?(context[:agent_id], 1, 256) do
      :ok
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp owned?(suggestion, owner),
    do: suggestion.session_id == owner.session_id and suggestion.agent_id == owner.agent_id

  defp required(input, key, limit) do
    value = optional_trim(input[key])
    if text?(value, 1, limit), do: {:ok, value}, else: {:error, :invalid_input}
  end

  defp optional_trim(value) when is_binary(value) do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    end
  end

  defp optional_trim(_), do: nil

  # The reference JavaScript string limits count UTF-16 code units, not bytes
  # or Elixir grapheme clusters. JSON capacity is separately counted in bytes.
  defp text?(value, minimum, maximum) when is_binary(value) do
    byte_size(value) <= maximum * 4 and String.valid?(value) and
      div(byte_size(:unicode.characters_to_binary(value, :utf8, :utf16)), 2) in minimum..maximum
  end

  defp text?(_, _, _), do: false
  defp absolute?(cwd), do: text?(cwd, 1, 4_096) and Path.type(cwd) == :absolute
  defp now, do: System.monotonic_time(:millisecond)

  defp publish(session_id, event),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, "task_suggestions:" <> session_id, event)
end
