defmodule Synapsis.Agent.Daemon do
  @moduledoc """
  Permanent control plane for daemon runs.

  Owns admission, idempotent submit, cancellation routing, boot reconciliation,
  liveness pulse, and bounded status. Never performs model or tool work in
  GenServer callbacks — that belongs to `RunCoordinator` children.
  """

  use GenServer
  require Logger

  alias Synapsis.Agent.RunCoordinator
  alias Synapsis.Agent.RunReconciler
  alias Synapsis.Agent.RunSupervisor
  alias Synapsis.Agent.Runs
  alias Synapsis.AgentRun

  @pulse_ms :timer.seconds(5)
  @status_scan_limit 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec submit(String.t(), keyword() | map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def submit(prompt, opts \\ []) when is_binary(prompt) do
    GenServer.call(__MODULE__, {:submit, prompt, normalize_opts(opts)}, 30_000)
  end

  @spec trigger(atom(), String.t() | nil, keyword() | map()) ::
          {:ok, AgentRun.t()} | {:error, term()}
  def trigger(kind, routine_id, opts \\ [])

  def trigger(kind, _routine_id, _opts)
      when kind in [:heartbeat, :dream, :schedule] do
    {:error, :not_implemented}
  end

  def trigger(_kind, _routine_id, _opts), do: {:error, :invalid_kind}

  @spec cancel(String.t(), term()) :: :ok | {:error, term()}
  def cancel(run_id, reason \\ :operator_request) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:cancel, run_id, reason}, 15_000)
  end

  @spec reconcile() :: {:ok, map()}
  def reconcile, do: GenServer.call(__MODULE__, :reconcile, 30_000)

  @impl true
  def init(_opts) do
    state = %{
      liveness_at: DateTime.utc_now(),
      last_reconcile_at: nil,
      storage_degraded?: false,
      pulse_ref: schedule_pulse()
    }

    {:ok, state, {:continue, :boot_reconcile}}
  end

  @impl true
  def handle_continue(:boot_reconcile, state) do
    {:noreply, do_reconcile(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call({:submit, prompt, opts}, _from, state) do
    case do_submit(prompt, opts) do
      {:ok, _run} = ok ->
        {:reply, ok, %{state | storage_degraded?: false}}

      {:error, reason} = err ->
        degraded = storage_error?(reason)
        {:reply, err, %{state | storage_degraded?: state.storage_degraded? or degraded}}
    end
  end

  def handle_call({:cancel, run_id, reason}, _from, state) do
    {:reply, do_cancel(run_id, reason), state}
  end

  def handle_call(:reconcile, _from, state) do
    new_state = do_reconcile(state)
    {:reply, {:ok, build_status(new_state)}, new_state}
  end

  @impl true
  def handle_info(:pulse, state) do
    _ = state.pulse_ref
    {:noreply, %{state | liveness_at: DateTime.utc_now(), pulse_ref: schedule_pulse()}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp do_submit(prompt, opts) do
    idempotency_key =
      Map.get(opts, :idempotency_key) ||
        Map.get(opts, "idempotency_key") ||
        Ecto.UUID.generate()

    attrs = %{
      kind: "manual",
      source: Map.get(opts, :source, "system"),
      assistant_name: Map.get(opts, :agent) || Map.get(opts, :assistant_name),
      prompt: prompt,
      tool_profile: "read_only",
      idempotency_key: idempotency_key,
      provider: Map.get(opts, :provider),
      model: Map.get(opts, :model),
      deadline_at: Map.get(opts, :deadline_at),
      policy_snapshot: %{"tool_profile" => "read_only", "attended" => false},
      capability_snapshot: %{"profile" => "read_only"},
      metadata: Map.get(opts, :metadata, %{})
    }

    with {:ok, run} <- Runs.create(attrs) do
      if AgentRun.terminal?(run) do
        {:ok, run}
      else
        case RunSupervisor.start_run(%{
               run_id: run.id,
               agent: attrs.assistant_name,
               provider: attrs.provider,
               model: attrs.model
             }) do
          {:ok, _pid} -> {:ok, Runs.get(run.id) || run}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp do_cancel(run_id, reason) do
    case Runs.get(run_id) do
      nil ->
        {:error, :not_found}

      %AgentRun{} = run ->
        if AgentRun.terminal?(run) do
          :ok
        else
          if RunSupervisor.alive?(run_id) do
            RunCoordinator.cancel(run_id, reason)
            :ok
          else
            case Runs.mark_cancelled(run, %{
                   "error" => "cancelled by operator",
                   "failure_class" => "cancelled"
                 }) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, reason}
            end
          end
        end
    end
  end

  defp do_reconcile(state) do
    now = DateTime.utc_now()

    incomplete =
      Runs.list_recent(limit: @status_scan_limit)
      |> Enum.reject(&AgentRun.terminal?/1)

    Enum.each(incomplete, fn run ->
      alive? = RunSupervisor.alive?(run.id)

      case RunReconciler.classify(run, %{alive?: alive?, now: now}) do
        {:keep, _} ->
          :ok

        {:reconcile, "timed_out", payload} ->
          _ = Runs.mark_timed_out(run, payload)

        {:reconcile, "unknown_outcome", payload} ->
          _ = Runs.mark_unknown_outcome(run, payload)

        {:reconcile, "failed", payload} ->
          _ = Runs.mark_failed(run, payload["error"] || "reconciled failure", payload)

        {:reconcile, _other, payload} ->
          _ = Runs.mark_failed(run, payload["error"] || "reconciled failure", payload)
      end
    end)

    %{state | last_reconcile_at: now, liveness_at: now}
  rescue
    error ->
      Logger.warning("daemon_reconcile_failed", reason: inspect(error))
      %{state | storage_degraded?: true, last_reconcile_at: DateTime.utc_now()}
  end

  defp build_status(state) do
    active_ids = RunSupervisor.list_active_run_ids()

    queued_count =
      Runs.list_recent(limit: @status_scan_limit)
      |> Enum.count(&(&1.status == "queued"))

    %{
      liveness_at: state.liveness_at,
      last_reconcile_at: state.last_reconcile_at,
      storage_degraded?: state.storage_degraded?,
      active_run_ids: active_ids,
      active_count: length(active_ids),
      queued_count: queued_count
    }
  end

  defp schedule_pulse do
    Process.send_after(self(), :pulse, @pulse_ms)
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts

  defp storage_error?(%Ecto.Changeset{}), do: false
  defp storage_error?(:injected_put_failure), do: true
  defp storage_error?({:error, _}), do: true
  defp storage_error?(_), do: false
end
