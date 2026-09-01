defmodule Synapsis.Agent.Daemon.Operations do
  @moduledoc false

  alias Synapsis.Agent.Daemon.{Execution, Recovery}

  def start(owner, task_supervisor, timeout, op, context) do
    case Execution.start_monitored_task(task_supervisor, fn ->
           result = Execution.protect(fn -> execute(op, context) end)
           send(owner, {:operation_result, self(), result})
         end) do
      {:ok, pid, ref} ->
        timer_ref = Process.send_after(owner, {:operation_timeout, ref, pid}, timeout)
        {:ok, ref, op |> Map.put(:pid, pid) |> Map.put(:timer_ref, timer_ref)}

      {:error, reason} ->
        {:error, {:task_start_failed, Execution.bounded_error(reason)}}
    end
  end

  def start_submit(owner, task_supervisor, timeout, entry, context) do
    case Execution.start_monitored_task(task_supervisor, fn ->
           result =
             Execution.persist_submission(
               context.deps,
               entry.attrs,
               entry.mode,
               task_supervisor,
               context.event_timeout
             )

           send(owner, {:submit_result, self(), entry.run_id, result})
         end) do
      {:ok, pid, ref} ->
        timer_ref =
          Process.send_after(owner, {:submit_operation_timeout, ref, pid, entry.run_id}, timeout)

        {:ok, %{pid: pid, ref: ref, run_id: entry.run_id, timer_ref: timer_ref}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{type: :cancel, location: :active, active: active}, context) do
    Execution.cancel_active(
      context.deps,
      context.task_supervisor,
      active,
      context.cleanup_timeout,
      context.event_timeout
    )
  end

  def execute(%{type: :cancel, location: :queued, run: run}, context) do
    Execution.cancel_queued(
      context.deps,
      context.task_supervisor,
      context.event_timeout,
      run
    )
  end

  def execute(%{type: :cancel, location: :unknown, run_id: run_id}, context),
    do: Execution.classify(context.deps.runs, run_id)

  def execute(%{type: :recovery, capacity: capacity}, context),
    do:
      Recovery.run(
        context.deps,
        capacity,
        context.task_supervisor,
        context.event_timeout
      )

  def execute(%{type: :refill, excluded: excluded, limit: limit}, context),
    do: Recovery.refill(context.deps, excluded, limit)

  def pop_by_pid(pending, pid) do
    case Enum.find(pending, fn {_ref, op} -> op.pid == pid end) do
      {ref, op} -> finish(pending, ref, op)
      nil -> :error
    end
  end

  def pop_by_ref(pending, ref) do
    case Map.pop(pending, ref) do
      {nil, _pending} ->
        :error

      {op, pending} ->
        cancel_timer(op.timer_ref)
        {:ok, op, pending}
    end
  end

  def retry(op), do: Map.drop(op, [:pid, :timer_ref])

  def cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  def cancel_timer(_ref), do: :ok

  defp finish(pending, ref, op) do
    Process.demonitor(ref, [:flush])
    cancel_timer(op.timer_ref)
    {:ok, op, Map.delete(pending, ref)}
  end
end
