defmodule Synapsis.Agent.DiffsCleanup do
  @moduledoc """
  Serial, supervised scheduling for data-owned Diffs cleanup claims.

  A sweep performs filesystem work in one bounded supervised task. Allocation
  requests an opportunistic sweep at most every five minutes. Explicit sweeps
  join existing work. Failed or interrupted removals retain their Concord claim;
  only acknowledged removal releases the namespace registration. Orphan scans
  include old recorded roots and exclude every currently registered directory.
  """

  use GenServer

  alias Synapsis.Diffs.ArtifactStore
  alias Synapsis.Workspace.DiffArtifacts

  @interval 300_000
  @timeout 30_000
  @orphan_age 86_400_000
  @max_bytes 32 * 1024 * 1024

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def allocated, do: GenServer.cast(__MODULE__, :allocated)

  def sweep(deadline) when is_integer(deadline) do
    remaining = deadline - now()

    if remaining > 0,
      do: GenServer.call(__MODULE__, {:sweep, deadline}, remaining),
      else: {:error, :timeout}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :cleanup_unavailable}
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{task: nil, timer: nil, waiters: [], last_started: nil, rerun: false}}
  end

  @impl true
  def handle_call({:sweep, deadline}, from, state) do
    if now() < deadline do
      state = %{state | waiters: [{from, deadline} | state.waiters]}
      # An allocation sweep may have read pending claims before this call's
      # retirement. Queue one fresh pass so manual acknowledgement includes it.
      {:noreply, if(state.task, do: %{state | rerun: true}, else: start_sweep(state, deadline))}
    else
      {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def handle_cast(:allocated, state) do
    due? = is_nil(state.last_started) or now() - state.last_started >= @interval

    {:noreply,
     if(is_nil(state.task) and due?, do: start_sweep(state, now() + @timeout), else: state)}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish(state, {:error, :cleanup_task_failed})}
  end

  def handle_info({:sweep_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, finish(state, {:error, :timeout})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: %Task{} = task}) do
    Task.shutdown(task, 5_000)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_sweep(state, requested_deadline) do
    deadline = min(requested_deadline, now() + @timeout)

    task =
      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn -> perform_sweep(deadline) end)

    timer = Process.send_after(self(), {:sweep_timeout, task.ref}, max(0, deadline - now()))
    %{state | task: task, timer: timer, last_started: now()}
  end

  defp finish(state, result) do
    if state.timer, do: Process.cancel_timer(state.timer)

    {ready, expired} =
      Enum.split_with(state.waiters, fn {_from, deadline} -> now() < deadline end)

    Enum.each(expired, fn {from, _deadline} -> GenServer.reply(from, {:error, :timeout}) end)
    state = %{state | task: nil, timer: nil, waiters: ready}

    if state.rerun and ready != [] do
      next_deadline = ready |> Enum.map(&elem(&1, 1)) |> Enum.min()
      start_sweep(%{state | rerun: false}, next_deadline)
    else
      Enum.each(ready, fn {from, _deadline} -> GenServer.reply(from, result) end)
      %{state | waiters: [], rerun: false}
    end
  end

  defp perform_sweep(deadline) do
    now_ms = System.system_time(:millisecond)

    with {:ok, _} <- ArtifactStore.claim_expired(now_ms, deadline),
         {:ok, pending} <- ArtifactStore.pending_cleanup(deadline),
         {:ok, removed} <- remove_claims(pending, deadline),
         {:ok, records} <- ArtifactStore.live_records(deadline),
         {:ok, roots} <- ArtifactStore.roots(deadline),
         {:ok, orphans_removed} <- remove_orphans(roots, records, now_ms, deadline) do
      {:ok, %{removed: removed, orphans_removed: orphans_removed}}
    end
  end

  defp remove_claims(records, deadline) do
    Enum.reduce_while(records, {:ok, 0}, fn record, {:ok, count} ->
      with :ok <- active(deadline),
           :ok <-
             DiffArtifacts.remove(record.root, record.public_id,
               max_bytes: record.max_bytes,
               deadline: deadline
             ),
           :ok <- ArtifactStore.ack_removed(record.id, record.revision, deadline) do
        {:cont, {:ok, count + 1}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp remove_orphans(roots, records, now_ms, deadline) do
    registered = MapSet.new(records, &{&1.root, &1.public_id})

    Enum.reduce_while(Enum.uniq(roots), {:ok, 0}, fn root, {:ok, count} ->
      with :ok <- active(deadline),
           {:ok, directories} <-
             DiffArtifacts.list_orphans(root, max_bytes: @max_bytes, deadline: deadline),
           {:ok, removed} <- remove_root_orphans(root, directories, registered, now_ms, deadline) do
        {:cont, {:ok, count + removed}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp remove_root_orphans(root, directories, registered, now_ms, deadline) do
    directories
    |> Enum.filter(
      &(&1.modified_at <= now_ms - @orphan_age and
          not MapSet.member?(registered, {root, &1.public_id}))
    )
    |> Enum.reduce_while({:ok, 0}, fn directory, {:ok, count} ->
      with :ok <- active(deadline),
           :ok <-
             DiffArtifacts.remove(root, directory.public_id,
               max_bytes: @max_bytes,
               deadline: deadline
             ) do
        {:cont, {:ok, count + 1}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp active(deadline), do: if(now() < deadline, do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)
end
