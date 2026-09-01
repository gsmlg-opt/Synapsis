defmodule Synapsis.Agent.Daemon do
  @moduledoc """
  Permanently supervised FIFO coordinator for durable manual agent runs.

  The GenServer owns only queue and monitor state. Store, event, PubSub, and
  session work runs in unlinked tasks under `RunTaskSupervisor`.
  """

  use GenServer

  alias Synapsis.Agent.{RunEvents, Runs}
  alias Synapsis.Agent.Daemon.{Execution, Recovery}
  alias Synapsis.AgentRun
  alias Synapsis.Sessions

  @topic "agent:daemon"
  @task_supervisor Synapsis.Agent.Daemon.RunTaskSupervisor
  @queue_capacity 25
  @run_timeout :timer.minutes(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def topic, do: @topic
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def submit(prompt, opts \\ %{}), do: submit(__MODULE__, prompt, opts)

  def submit(server, prompt, opts) do
    with {:ok, attrs} <- Execution.manual_attrs(prompt, opts) do
      GenServer.call(server, {:submit, attrs})
    end
  end

  def cancel(run_id), do: cancel(__MODULE__, run_id)
  def cancel(server, run_id) when is_binary(run_id), do: GenServer.call(server, {:cancel, run_id})
  def cancel(_server, _run_id), do: {:error, :invalid_run_id}

  @impl true
  def init(opts) do
    config = Application.get_env(:synapsis_agent, __MODULE__, [])
    recover? = Keyword.get(opts, :recover?, true)

    state = %{
      ready: not recover?,
      active_run: nil,
      queue: :queue.new(),
      cancelling_ids: MapSet.new(),
      pending: %{},
      queue_capacity:
        opts
        |> Keyword.get(:queue_capacity, Keyword.get(config, :queue_capacity, @queue_capacity))
        |> Execution.valid_capacity(@queue_capacity),
      task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
      run_timeout: Keyword.get(opts, :run_timeout, @run_timeout),
      deps: %{
        runs: Keyword.get(opts, :runs, Runs),
        run_events: Keyword.get(opts, :run_events, RunEvents),
        sessions: Keyword.get(opts, :sessions, Sessions)
      },
      last_error: nil,
      recovery_error: nil
    }

    send(self(), if(recover?, do: :recover, else: :status_changed))
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, Execution.status(state), state}

  def handle_call({:submit, attrs}, from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, :not_ready}, state}

      queue_load(state) >= state.queue_capacity ->
        {:reply, {:error, :queue_full}, state}

      true ->
        case start_operation(state, %{type: :submit, from: from}, fn ->
               Execution.submit(state.deps, attrs)
             end) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:reply, {:error, reason}, put_error(state, reason)}
        end
    end
  end

  def handle_call({:cancel, run_id}, from, state) do
    case locate_run(state, run_id) do
      {:active, active} when active.cancelling ->
        {:reply, {:error, :cancellation_in_progress}, state}

      {:active, active} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :active}

        case start_operation(state, op, fn ->
               Execution.cancel_active(state.deps, state.task_supervisor, active)
             end) do
          {:ok, state} ->
            active = %{active | cancelling: true}
            {:noreply, %{state | active_run: active}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      {:queued, run} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :queued}

        case start_operation(state, op, fn -> Execution.cancel_queued(state.deps, run) end) do
          {:ok, state} ->
            {:noreply, %{state | cancelling_ids: MapSet.put(state.cancelling_ids, run_id)}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      :unknown ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :unknown}

        case start_operation(state, op, fn -> Execution.classify(state.deps.runs, run_id) end) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:reply, {:error, reason}, put_error(state, reason)}
        end
    end
  end

  @impl true
  def handle_info(:recover, state) do
    case start_operation(state, %{type: :recovery}, fn -> Recovery.run(state.deps) end) do
      {:ok, state} ->
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :recover, 25)
        {:noreply, state}
    end
  end

  def handle_info(:drain, %{active_run: nil} = state) do
    case :queue.peek(state.queue) do
      {:value, run} ->
        if MapSet.member?(state.cancelling_ids, run.id) do
          {:noreply, state}
        else
          case start_runner(state, run) do
            {:ok, task_pid, task_ref} ->
              {{:value, ^run}, queue} = :queue.out(state.queue)

              active = %{
                run: run,
                task_pid: task_pid,
                task_ref: task_ref,
                phase: :starting,
                cancelling: false,
                degraded: false,
                error: nil
              }

              {:noreply, %{state | queue: queue, active_run: active}}

            {:error, reason} ->
              Process.send_after(self(), :drain, 100)
              new_state = put_error(state, {:run_task_start_failed, reason})
              dispatch_status(new_state)
              {:noreply, new_state}
          end
        end

      :empty ->
        {:noreply, state}
    end
  end

  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info(:status_changed, state) do
    dispatch_status(state)
    {:noreply, state}
  end

  def handle_info(
        {:runner_started, task_pid, %AgentRun{} = run},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      )
      when run.id == run_id do
    send(task_pid, {:runner_started_ack, run.id})
    new_state = %{state | active_run: %{active | run: run, phase: :running}}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  def handle_info({:operation_result, task_pid, result}, state) do
    case pop_operation(state, task_pid) do
      {:ok, op, state} -> handle_operation_result(op, result, state)
      :error -> {:noreply, state}
    end
  end

  def handle_info(
        {:runner_result, task_pid, run_id, result},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      ) do
    Process.demonitor(active.task_ref, [:flush])
    handle_runner_result(result, active, state)
  end

  def handle_info({:runner_result, _task_pid, _run_id, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      state.active_run && state.active_run.task_ref == ref ->
        handle_runner_down(pid, reason, state)

      true ->
        handle_operation_down(ref, reason, state)
    end
  end

  defp handle_operation_result(%{type: :submit, from: from}, {:ok, run}, state) do
    GenServer.reply(from, {:ok, run})
    new_state = %{state | queue: :queue.in(run, state.queue)}
    dispatch_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :submit, from: from}, {:error, reason}, state) do
    GenServer.reply(from, {:error, reason})
    {:noreply, put_error(state, reason)}
  end

  defp handle_operation_result(
         %{type: :cancel, from: from, run_id: id, location: location},
         {:ok, cancelled},
         state
       ) do
    GenServer.reply(from, {:ok, cancelled})

    new_state =
      case location do
        :active -> %{state | active_run: nil}
        :queued -> %{state | queue: remove_queued(state.queue, id)}
      end
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, id))

    dispatch_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :cancel, from: from} = op, {:error, reason}, state) do
    GenServer.reply(from, {:error, reason})

    new_state =
      state
      |> Map.update!(:cancelling_ids, &MapSet.delete(&1, op.run_id))
      |> maybe_reset_cancelling(op)
      |> put_error(reason)

    dispatch_status(new_state)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :recovery}, {:ok, interrupted, queued, errors}, state) do
    recovery_error = join_errors(errors)

    new_state = %{
      state
      | ready: true,
        queue: :queue.from_list(queued),
        recovery_error: recovery_error,
        last_error: recovery_error
    }

    _ = interrupted
    dispatch_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  defp handle_operation_result(%{type: :recovery}, {:error, reason}, state) do
    error = Execution.bounded_error(reason)
    new_state = %{state | ready: true, recovery_error: error, last_error: error}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  defp handle_runner_result({:ok, terminal_run}, _active, state) do
    last_error =
      if terminal_run.status == "failed",
        do: Execution.bounded_error(terminal_run.error),
        else: nil

    new_state = %{state | active_run: nil, last_error: last_error}
    dispatch_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  defp handle_runner_result({:error, reason, run}, active, state) do
    error = Execution.bounded_error(reason)

    degraded = %{
      active
      | run: run || active.run,
        task_pid: nil,
        task_ref: nil,
        phase: :degraded,
        degraded: true,
        error: error
    }

    new_state = %{state | active_run: degraded, last_error: error}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  defp handle_runner_down(_pid, _reason, %{active_run: %{cancelling: true} = active} = state) do
    active = %{active | task_pid: nil, task_ref: nil, phase: :cancelling}
    {:noreply, %{state | active_run: active}}
  end

  defp handle_runner_down(_pid, reason, %{active_run: active} = state) do
    error = "run task exited: #{Execution.bounded_error(reason)}"

    case start_finalizer(state, active.run, {:error, error}) do
      {:ok, task_pid, task_ref} ->
        active = %{active | task_pid: task_pid, task_ref: task_ref, phase: :finalizing}
        {:noreply, %{state | active_run: active}}

      {:error, start_reason} ->
        error = Execution.bounded_error({:finalizer_task_start_failed, start_reason})

        active = %{
          active
          | task_pid: nil,
            task_ref: nil,
            phase: :degraded,
            degraded: true,
            error: error
        }

        new_state = %{state | active_run: active, last_error: error}
        dispatch_status(new_state)
        {:noreply, new_state}
    end
  end

  defp handle_operation_down(ref, reason, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from} = op, pending} ->
        error = Execution.bounded_error({:operation_task_exit, reason})
        GenServer.reply(from, {:error, error})

        state =
          %{state | pending: pending}
          |> Map.update!(:cancelling_ids, &MapSet.delete(&1, Map.get(op, :run_id)))
          |> maybe_reset_cancelling(op)
          |> put_error(error)

        {:noreply, state}

      {%{type: :recovery}, pending} ->
        error = Execution.bounded_error({:recovery_task_exit, reason})

        new_state = %{
          state
          | pending: pending,
            ready: true,
            recovery_error: error,
            last_error: error
        }

        dispatch_status(new_state)
        {:noreply, new_state}
    end
  end

  defp start_operation(state, op, fun) do
    daemon = self()

    case Execution.start_monitored_task(state.task_supervisor, fn ->
           result = Execution.protect(fun)
           send(daemon, {:operation_result, self(), result})
         end) do
      {:ok, pid, ref} ->
        {:ok, %{state | pending: Map.put(state.pending, ref, Map.put(op, :pid, pid))}}

      {:error, reason} ->
        {:error, {:task_start_failed, Execution.bounded_error(reason)}}
    end
  end

  defp start_runner(state, run) do
    daemon = self()

    with {:ok, pid, ref} <-
           Execution.start_monitored_task(state.task_supervisor, fn ->
             Execution.run(daemon, state.deps, run, state.run_timeout)
           end) do
      {:ok, pid, ref}
    end
  end

  defp start_finalizer(state, run, result) do
    daemon = self()

    with {:ok, pid, ref} <-
           Execution.start_monitored_task(state.task_supervisor, fn ->
             terminal =
               case Execution.protect(fn -> Execution.finalize(state.deps, run, result) end) do
                 {:error, reason} -> {:error, reason, run}
                 terminal -> terminal
               end

             send(daemon, {:runner_result, self(), run.id, terminal})
           end) do
      {:ok, pid, ref}
    end
  end

  defp dispatch_status(state) do
    status = Execution.status(state)
    _ = Execution.start_task(state.task_supervisor, fn -> Execution.publish_status(status) end)
    :ok
  end

  defp locate_run(state, run_id) do
    cond do
      state.active_run && state.active_run.run.id == run_id -> {:active, state.active_run}
      run = Enum.find(:queue.to_list(state.queue), &(&1.id == run_id)) -> {:queued, run}
      true -> :unknown
    end
  end

  defp pop_operation(state, pid) do
    case Enum.find(state.pending, fn {_ref, op} -> op.pid == pid end) do
      {ref, op} ->
        Process.demonitor(ref, [:flush])
        {:ok, op, %{state | pending: Map.delete(state.pending, ref)}}

      nil ->
        :error
    end
  end

  defp maybe_reset_cancelling(state, %{type: :cancel, location: :active, run_id: id}) do
    case state.active_run do
      %{run: %{id: ^id}} = active -> %{state | active_run: %{active | cancelling: false}}
      _other -> state
    end
  end

  defp maybe_reset_cancelling(state, _op), do: state

  defp remove_queued(queue, run_id) do
    queue |> :queue.to_list() |> Enum.reject(&(&1.id == run_id)) |> :queue.from_list()
  end

  defp queue_load(state) do
    pending_submits = Enum.count(state.pending, fn {_ref, op} -> op.type == :submit end)
    :queue.len(state.queue) + pending_submits
  end

  defp put_error(state, reason), do: %{state | last_error: Execution.bounded_error(reason)}

  defp join_errors([]), do: nil
  defp join_errors(errors), do: Execution.bounded_error({:recovery_partial_failure, errors})
end
