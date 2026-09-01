defmodule Synapsis.Agent.Daemon.Recovery do
  @moduledoc false

  alias Synapsis.Agent.Daemon.Execution

  def run(deps, capacity, task_supervisor, event_timeout) do
    {running, running_errors} = load_status(deps.runs, "running")
    {waiting, waiting_errors} = load_status(deps.runs, "waiting_approval")
    {queued, queued_errors} = load_status(deps.runs, "queued")
    scan_errors = running_errors ++ waiting_errors ++ queued_errors

    {interrupt_errors, event_errors, _interrupted} =
      interrupt(deps, task_supervisor, event_timeout, running ++ waiting)

    errors = scan_errors ++ interrupt_errors

    if errors == [] do
      {selected, backlog} = select(queued, MapSet.new(), capacity)
      {:ok, selected, backlog, event_errors}
    else
      {:retry, errors}
    end
  end

  def refill(deps, excluded_ids, limit) do
    case deps.runs.list_by_status_result("queued", limit: :all) do
      {:ok, queued} ->
        {selected, backlog} = select(queued, excluded_ids, limit)
        {:ok, selected, backlog}

      {:error, reason} ->
        {:retry, [{"queued", reason}]}
    end
  end

  defp interrupt(deps, task_supervisor, event_timeout, runs) do
    Enum.reduce(runs, {[], [], []}, fn run, {errors, event_errors, interrupted} ->
      case deps.runs.mark_interrupted(run, "daemon_restarted") do
        {:ok, terminal} ->
          warnings =
            Execution.emit_run_event(
              task_supervisor,
              event_timeout,
              deps,
              :interrupted,
              terminal,
              "agent.run.interrupted",
              %{reason: "daemon_restarted"}
            )

          {errors, event_errors ++ warnings, [terminal | interrupted]}

        {:error, reason} ->
          {[{run.id, reason} | errors], event_errors, interrupted}
      end
    end)
  end

  defp select(queued, excluded_ids, limit) do
    available =
      queued
      |> Enum.reject(&MapSet.member?(excluded_ids, &1.id))
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    {selected, backlog} = Enum.split(available, limit)
    {selected, length(backlog)}
  end

  defp load_status(runs, status) do
    case runs.list_by_status_result(status, limit: :all) do
      {:ok, found} -> {found, []}
      {:error, reason} -> {[], [{status, reason}]}
    end
  end
end
