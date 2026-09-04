defmodule Synapsis.Agent.RunCoordinator do
  @moduledoc """
  Per-run orchestration process.

  Creates/attaches a session, submits the prompt, consumes typed session
  terminals, and persists run lifecycle facts via `Runs`. Does not execute
  tools or call providers itself.
  """

  use GenServer
  require Logger

  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.Agent.RunSupervisor
  alias Synapsis.Agent.Runs
  alias Synapsis.AgentRun
  alias Synapsis.Sessions

  def child_spec(opts) do
    run_id = opts[:run_id] || opts["run_id"]

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts) when is_list(opts), do: start_link(Map.new(opts))

  def start_link(%{run_id: run_id} = opts) when is_binary(run_id) do
    GenServer.start_link(__MODULE__, opts, name: RunSupervisor.via(run_id))
  end

  @spec cancel(pid() | String.t(), term()) :: :ok
  def cancel(run_id, reason \\ :operator_request)

  def cancel(run_id, reason) when is_binary(run_id) do
    case RunSupervisor.whereis(run_id) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:cancel, reason})
      nil -> :ok
    end
  end

  def cancel(pid, reason) when is_pid(pid), do: GenServer.cast(pid, {:cancel, reason})

  @impl true
  def init(opts) do
    run_id = Map.fetch!(opts, :run_id)

    state = %{
      run_id: run_id,
      session_id: nil,
      deadline_ref: nil,
      terminal?: false,
      opts: opts
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case Runs.get(state.run_id) do
      nil ->
        Logger.warning("run_coordinator_missing_run", run_id: state.run_id)
        {:stop, :normal, state}

      %AgentRun{} = run ->
        if AgentRun.terminal?(run) do
          {:stop, :normal, state}
        else
          do_bootstrap(run, state)
        end
    end
  end

  @impl true
  def handle_cast({:cancel, reason}, %{terminal?: true} = state) do
    _ = reason
    {:noreply, state}
  end

  def handle_cast({:cancel, reason}, state) do
    message = cancel_message(reason)

    if is_binary(state.session_id) do
      _ = Sessions.cancel(state.session_id)
    end

    case finalize(state, "run.cancelled", %{"error" => message, "failure_class" => "cancelled"}) do
      {:ok, new_state} -> {:stop, :normal, new_state}
      {:error, _} -> {:stop, :normal, %{state | terminal?: true}}
    end
  end

  @impl true
  def handle_info(:deadline, %{terminal?: true} = state), do: {:noreply, state}

  def handle_info(:deadline, state) do
    if is_binary(state.session_id) do
      _ = Sessions.cancel(state.session_id)
    end

    case finalize(state, "run.timed_out", %{
           "error" => "deadline exceeded",
           "failure_class" => "timeout"
         }) do
      {:ok, new_state} -> {:stop, :normal, new_state}
      {:error, _} -> {:stop, :normal, %{state | terminal?: true}}
    end
  end

  def handle_info({:run_event, %RunEvent{} = event}, %{terminal?: true} = state) do
    _ = event
    {:noreply, state}
  end

  def handle_info({:run_event, %RunEvent{} = event}, state) do
    if match_terminal?(event, state) do
      {type, payload} = map_session_terminal(event)

      case finalize(state, type, payload) do
        {:ok, new_state} -> {:stop, :normal, new_state}
        {:error, _} -> {:stop, :normal, %{state | terminal?: true}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp do_bootstrap(%AgentRun{} = run, state) do
    with {:ok, run} <- ensure_starting(run),
         {:ok, session} <- create_session(run, state.opts),
         :ok <- subscribe(session.id),
         {:ok, run} <-
           Runs.mark_running(run, %{
             session_id: session.id,
             started_at: run.started_at || DateTime.utc_now()
           }),
         :ok <- send_prompt(session.id, run.prompt) do
      deadline_ref = schedule_deadline(run)

      {:noreply, %{state | session_id: session.id, deadline_ref: deadline_ref}}
    else
      {:error, reason} ->
        Logger.warning("run_coordinator_bootstrap_failed",
          run_id: state.run_id,
          reason: inspect(reason)
        )

        _ =
          case Runs.get(state.run_id) do
            %AgentRun{} = r ->
              Runs.mark_failed(r, bootstrap_error(reason), %{"failure_class" => "bootstrap"})

            _ ->
              :ok
          end

        {:stop, :normal, %{state | terminal?: true}}
    end
  end

  defp ensure_starting(%AgentRun{status: "queued"} = run), do: Runs.mark_starting(run)
  defp ensure_starting(%AgentRun{status: "starting"} = run), do: {:ok, run}
  defp ensure_starting(%AgentRun{status: "running"} = run), do: {:ok, run}
  defp ensure_starting(%AgentRun{} = run), do: {:ok, run}

  defp create_session(%AgentRun{} = run, opts) do
    agent = Map.get(opts, :agent) || run.assistant_name || "main"

    Sessions.create(agent, %{
      agent: agent,
      provider: Map.get(opts, :provider) || run.provider,
      model: Map.get(opts, :model) || run.model,
      title: "daemon-run-#{run.id}"
    })
  end

  defp subscribe(session_id) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
  end

  defp send_prompt(session_id, prompt) when is_binary(prompt) do
    case Sessions.send_message(session_id, prompt) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_deadline(%AgentRun{deadline_at: %DateTime{} = deadline}) do
    now = DateTime.utc_now()
    ms = DateTime.diff(deadline, now, :millisecond)

    if ms <= 0 do
      send(self(), :deadline)
      nil
    else
      Process.send_after(self(), :deadline, ms)
    end
  end

  defp schedule_deadline(_run), do: nil

  defp match_terminal?(%RunEvent{} = event, state) do
    RunEvent.session_terminal?(event) and
      event.session_id == state.session_id and
      (is_nil(event.run_id) or event.run_id == state.run_id)
  end

  defp map_session_terminal(%RunEvent{type: "session.completed"} = event) do
    summary =
      Map.get(event.payload, "summary") ||
        Map.get(event.payload, "message") ||
        "completed"

    {"run.completed", %{"summary" => summary}}
  end

  defp map_session_terminal(%RunEvent{type: "session.failed"} = event) do
    error = Map.get(event.payload, "message") || Map.get(event.payload, "error") || "failed"
    {"run.failed", %{"error" => error, "failure_class" => "session"}}
  end

  defp map_session_terminal(%RunEvent{type: "session.cancelled"} = event) do
    error = Map.get(event.payload, "message") || "cancelled"
    {"run.cancelled", %{"error" => error, "failure_class" => "cancelled"}}
  end

  defp map_session_terminal(%RunEvent{type: "session.timed_out"} = event) do
    error = Map.get(event.payload, "message") || "timed out"
    {"run.timed_out", %{"error" => error, "failure_class" => "timeout"}}
  end

  defp finalize(state, type, payload) do
    cancel_deadline(state.deadline_ref)

    case Runs.get(state.run_id) do
      %AgentRun{} = run ->
        if AgentRun.terminal?(run) do
          {:ok, %{state | terminal?: true}}
        else
          result =
            case type do
              "run.completed" ->
                Runs.mark_completed(run, payload["summary"] || "completed", payload)

              "run.failed" ->
                Runs.mark_failed(run, payload["error"] || "failed", payload)

              "run.cancelled" ->
                Runs.mark_cancelled(run, payload)

              "run.timed_out" ->
                Runs.mark_timed_out(run, payload)

              "run.unknown_outcome" ->
                Runs.mark_unknown_outcome(run, payload)

              _ ->
                {:error, :unknown_terminal}
            end

          case result do
            {:ok, _} -> {:ok, %{state | terminal?: true}}
            other -> other
          end
        end

      nil ->
        {:error, :run_missing}
    end
  end

  defp cancel_deadline(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_deadline(_), do: :ok

  defp cancel_message(:operator_request), do: "cancelled by operator"
  defp cancel_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp cancel_message(reason) when is_binary(reason), do: reason
  defp cancel_message(reason), do: inspect(reason)

  defp bootstrap_error(reason) when is_binary(reason), do: reason
  defp bootstrap_error(reason), do: "bootstrap failed: #{inspect(reason)}"
end
