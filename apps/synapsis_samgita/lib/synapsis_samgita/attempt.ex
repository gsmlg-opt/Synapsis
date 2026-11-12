defmodule SynapsisSamgita.Attempt do
  @moduledoc """
  One claimed Samgita attempt, driven step by step by the operator.

  Owns the attempt `version` and current owner `proof` (never exposed), renews
  the 120 s lease every `renew_interval_ms` and re-reads the proof after every
  renew (renewal rotates it). A failed step leaves state unchanged. After a
  successful report the process stops normally; if the lease passes while
  renewals fail, the attempt is marked `"lost"` and stops.

  Not durable: a Synapsis restart abandons the attempt until its lease expires.
  """
  use GenServer, restart: :temporary

  require Logger
  alias SynapsisSamgita.{API, Events}

  @default_renew_interval_ms 60_000
  @default_retry_interval_ms 5_000
  # Extra verbatim attempts for a write whose outcome is unknown (transport failure).
  @uncertain_retries 2
  @call_timeout 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  def view(pid), do: GenServer.call(pid, :view, @call_timeout)
  def start_work(pid), do: GenServer.call(pid, :start, @call_timeout)
  def progress(pid, summary), do: GenServer.call(pid, {:progress, summary}, @call_timeout)

  def report(pid, outcome, effects_resolved, result),
    do: GenServer.call(pid, {:report, outcome, effects_resolved, result}, @call_timeout)

  defp name(opts) do
    case Keyword.get(opts, :registry, SynapsisSamgita.AttemptRegistry) do
      nil -> nil
      registry -> {:via, Registry, {registry, opts[:attempt]["id"]}}
    end
  end

  @impl true
  def init(opts) do
    attempt = Keyword.fetch!(opts, :attempt)

    state = %{
      conn: Keyword.fetch!(opts, :conn),
      project_id: Keyword.fetch!(opts, :project_id),
      id: attempt["id"],
      task_id: attempt["task_id"],
      state: attempt["state"],
      version: attempt["version"],
      lease_expires_at: attempt["lease_expires_at"],
      proof: nil,
      proof_stale: true,
      last_error: nil,
      notify: Keyword.get(opts, :notify, SynapsisSamgita.Connection),
      api: Keyword.get(opts, :api, API),
      interval: Keyword.get(opts, :renew_interval_ms, @default_renew_interval_ms),
      retry_interval: Keyword.get(opts, :retry_interval_ms, @default_retry_interval_ms)
    }

    {:ok, state, {:continue, :proof}}
  end

  @impl true
  def handle_continue(:proof, state) do
    state = refresh_proof(state)
    schedule_renew(state, if(state.proof_stale, do: state.retry_interval, else: state.interval))
    {:noreply, publish(state)}
  end

  @impl true
  def handle_call(:view, _from, state), do: {:reply, view_of(state), state}

  def handle_call(:start, _from, state) do
    step(state, fn s, opts ->
      s.api.start(s.conn, s.project_id, s.id, s.version, s.proof, opts)
    end)
  end

  def handle_call({:progress, summary}, _from, state) do
    step(state, fn s, opts ->
      s.api.progress(s.conn, s.project_id, s.id, s.version, s.proof, summary, opts)
    end)
  end

  def handle_call({:report, outcome, effects_resolved, result}, _from, state) do
    report = fn s, opts ->
      s.api.report(
        s.conn,
        s.project_id,
        s.id,
        s.version,
        s.proof,
        outcome,
        effects_resolved,
        result,
        opts
      )
    end

    case step(state, report) do
      {:reply, {:ok, _} = reply, state} ->
        Logger.info("samgita_attempt_reported", attempt_id: state.id, outcome: outcome)
        {:stop, :normal, reply, state}

      other ->
        other
    end
  end

  # A proof that could not be re-read after a renew is refreshed first: the old
  # one is invalid once a renew rotates it. Failures retry on the short
  # interval so a transient error is retried well within the 120 s lease.
  @impl true
  def handle_info(:renew, %{proof_stale: true} = state), do: after_renew(refresh_proof(state))

  def handle_info(:renew, state) do
    state =
      case with_retries(fn opts ->
             state.api.renew(
               state.conn,
               state.project_id,
               state.id,
               state.version,
               state.proof,
               opts
             )
           end) do
        {:ok, attempt} ->
          state |> apply_attempt(attempt) |> Map.put(:proof_stale, true) |> refresh_proof()

        {:error, error} ->
          %{state | last_error: error.code}
      end

    after_renew(state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp after_renew(state) do
    failed? = state.proof_stale or not is_nil(state.last_error)

    cond do
      failed? and lease_expired?(state) ->
        Logger.warning("samgita_attempt_lost", attempt_id: state.id, reason: state.last_error)
        {:stop, :normal, publish(%{state | state: "lost"})}

      failed? ->
        schedule_renew(state, state.retry_interval)
        {:noreply, publish(state)}

      true ->
        schedule_renew(state, state.interval)
        {:noreply, publish(state)}
    end
  end

  defp step(state, fun) do
    case with_retries(&fun.(state, &1)) do
      {:ok, attempt} ->
        state = state |> apply_attempt(attempt) |> Map.put(:last_error, nil) |> publish()
        {:reply, {:ok, view_of(state)}, state}

      {:error, error} ->
        state = publish(%{state | last_error: error.code})
        {:reply, {:error, error}, state}
    end
  end

  defp apply_attempt(state, attempt) do
    %{
      state
      | state: attempt["state"] || state.state,
        version: attempt["version"] || state.version,
        lease_expires_at: attempt["lease_expires_at"] || state.lease_expires_at
    }
  end

  # Retry a write whose outcome is unknown with the same command_id and body, so
  # Samgita replays the stored result instead of applying it twice.
  defp with_retries(fun, command_id \\ Ecto.UUID.generate(), left \\ @uncertain_retries) do
    case fun.(command_id: command_id) do
      {:error, %{status: nil}} when left > 0 -> with_retries(fun, command_id, left - 1)
      result -> result
    end
  end

  defp refresh_proof(state) do
    case state.api.proof(state.conn, state.project_id, state.id) do
      {:ok, proof} -> %{state | proof: proof, proof_stale: false, last_error: nil}
      {:error, error} -> %{state | proof_stale: true, last_error: error.code}
    end
  end

  defp schedule_renew(_state, interval), do: Process.send_after(self(), :renew, interval)

  defp lease_expired?(%{lease_expires_at: at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} -> DateTime.compare(at, DateTime.utc_now()) != :gt
      _ -> false
    end
  end

  defp lease_expired?(_), do: false

  defp publish(state) do
    view = view_of(state)
    send_view(state.notify, view)
    Events.broadcast_attempt(view)
    state
  end

  defp send_view(nil, _view), do: :ok
  defp send_view(pid, view) when is_pid(pid), do: send(pid, {:attempt_view, view})
  defp send_view(name, view), do: GenServer.cast(name, {:attempt_view, view})

  defp view_of(state) do
    Map.take(state, [:id, :project_id, :task_id, :state, :version, :lease_expires_at, :last_error])
  end
end
