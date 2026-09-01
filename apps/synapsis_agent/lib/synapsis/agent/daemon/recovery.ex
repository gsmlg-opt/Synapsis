defmodule Synapsis.Agent.Daemon.Recovery do
  @moduledoc false

  alias Synapsis.Agent.Daemon.Execution

  def run(deps) do
    {running, running_errors} = load_status(deps.runs, "running")
    {waiting, waiting_errors} = load_status(deps.runs, "waiting_approval")
    {queued, queued_errors} = load_status(deps.runs, "queued")

    {interrupted, interrupt_errors} = interrupt(deps, running ++ waiting)
    queued = Enum.sort_by(queued, & &1.inserted_at, {:asc, DateTime})
    errors = running_errors ++ waiting_errors ++ queued_errors ++ interrupt_errors
    {:ok, interrupted, queued, errors}
  end

  defp interrupt(deps, runs) do
    {interrupted, errors} =
      Enum.reduce(runs, {[], []}, fn run, {ok, errors} ->
        case deps.runs.mark_interrupted(run, "daemon_restarted") do
          {:ok, interrupted} ->
            _ = Execution.append_event(deps, :interrupted, interrupted)

            _ =
              Execution.publish_run("agent.run.interrupted", interrupted, %{
                reason: "daemon_restarted"
              })

            {[interrupted | ok], errors}

          {:error, reason} ->
            {ok, [{run.id, reason} | errors]}
        end
      end)

    {Enum.reverse(interrupted), errors}
  end

  defp load_status(runs, status) do
    case runs.list_by_status_result(status, limit: :all) do
      {:ok, found} -> {found, []}
      {:error, reason} -> {[], [{status, reason}]}
    end
  end
end
