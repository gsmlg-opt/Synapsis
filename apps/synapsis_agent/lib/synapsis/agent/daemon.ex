defmodule Synapsis.Agent.Daemon do
  @moduledoc """
  Permanently supervised, single-run coordinator for durable agent runs.

  Session execution stays on the existing `Synapsis.Sessions` and
  `Synapsis.Session.Worker` path. The daemon only owns bounded FIFO state;
  long waits happen in tasks under `RunTaskSupervisor`.
  """

  use GenServer

  alias Synapsis.Agent.{RunEvents, Runs}
  alias Synapsis.AgentRun
  alias Synapsis.Sessions

  @topic "agent:daemon"
  @default_task_supervisor Synapsis.Agent.Daemon.RunTaskSupervisor
  @default_queue_capacity 25
  @default_run_timeout :timer.minutes(30)

  @string_options ~w(assistant_name provider model source tool_profile)a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The single bounded PubSub topic for daemon lifecycle events."
  def topic, do: @topic

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def submit(prompt, opts \\ %{}), do: submit(__MODULE__, prompt, opts)

  def submit(server, prompt, opts) when is_map(opts) do
    with :ok <- validate_prompt(prompt),
         {:ok, opts} <- validate_options(opts) do
      GenServer.call(server, {:submit, prompt, opts})
    end
  end

  def submit(_server, prompt, _opts) do
    with :ok <- validate_prompt(prompt), do: {:error, :invalid_options}
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
      queue_capacity:
        opts |> Keyword.get(:queue_capacity, configured_capacity(config)) |> valid_capacity(),
      task_supervisor: Keyword.get(opts, :task_supervisor, @default_task_supervisor),
      run_timeout: Keyword.get(opts, :run_timeout, @default_run_timeout),
      last_error: nil,
      recovery_error: nil,
      recovery_task_ref: nil
    }

    send(self(), if(recover?, do: :recover, else: :broadcast_status))
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:submit, prompt, opts}, _from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, :not_ready}, state}

      :queue.len(state.queue) >= state.queue_capacity ->
        {:reply, {:error, :queue_full}, state}

      true ->
        attrs = %{
          kind: "manual",
          status: "queued",
          source: option(opts, :source, "web"),
          assistant_name: option(opts, :assistant_name, "main"),
          prompt: prompt,
          tool_profile: option(opts, :tool_profile, "read_only"),
          provider: option(opts, :provider),
          model: option(opts, :model),
          metadata: option(opts, :metadata, %{})
        }

        case Runs.create(attrs) do
          {:ok, run} ->
            RunEvents.append_run_created(run)
            broadcast_run("agent.run.queued", run)
            send(self(), :drain)
            send(self(), :broadcast_status)
            {:reply, {:ok, run}, %{state | queue: :queue.in(run, state.queue)}}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | last_error: error_message(reason)}}
        end
    end
  end

  def handle_call({:cancel, run_id}, _from, state) do
    case cancel_owned_run(state, run_id) do
      {:ok, cancelled, state} ->
        send(self(), :drain)
        send(self(), :broadcast_status)
        {:reply, {:ok, cancelled}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:recover, state) do
    daemon = self()

    case start_task(state.task_supervisor, fn ->
           send(daemon, {:recovery_result, self(), recover_runs(state.queue_capacity)})
         end) do
      {:ok, task_pid} ->
        {:noreply, %{state | recovery_task_ref: Process.monitor(task_pid)}}

      {:error, _reason} ->
        Process.send_after(self(), :recover, 25)
        {:noreply, state}
    end
  end

  def handle_info(
        {:recovery_result, _task_pid, {:ok, interrupted, queued}},
        %{recovery_task_ref: task_ref} = state
      ) do
    Process.demonitor(task_ref, [:flush])

    Enum.each(interrupted, fn run ->
      RunEvents.append_run_interrupted(run)
      broadcast_run("agent.run.interrupted", run, %{reason: "daemon_restarted"})
    end)

    Enum.each(queued, &broadcast_run("agent.run.queued", &1, %{recovered: true}))

    new_state = %{
      state
      | ready: true,
        queue: :queue.from_list(queued),
        recovery_error: nil,
        recovery_task_ref: nil
    }

    broadcast_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  def handle_info(
        {:recovery_result, _task_pid, {:error, reason}},
        %{recovery_task_ref: task_ref} = state
      ) do
    Process.demonitor(task_ref, [:flush])
    error = error_message(reason)

    new_state = %{
      state
      | ready: true,
        last_error: error,
        recovery_error: error,
        recovery_task_ref: nil
    }

    broadcast_status(new_state)
    {:noreply, new_state}
  end

  def handle_info(:broadcast_status, state) do
    broadcast_status(state)
    {:noreply, state}
  end

  def handle_info(:drain, %{active_run: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, run}, queue} ->
        daemon = self()

        case Task.Supervisor.start_child(state.task_supervisor, fn ->
               execute_run(daemon, run, state.run_timeout)
             end) do
          {:ok, task_pid} ->
            task_ref = Process.monitor(task_pid)

            {:noreply,
             %{
               state
               | queue: queue,
                 active_run: %{run: run, task_pid: task_pid, task_ref: task_ref}
             }}

          {:error, reason} ->
            state = fail_run(state, run, "could not start run task: #{inspect(reason)}")
            send(self(), :drain)
            {:noreply, %{state | queue: queue}}
        end

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info(
        {:run_started, task_pid, %AgentRun{} = run},
        %{active_run: %{task_pid: task_pid, run: %{id: run_id}} = active} = state
      )
      when run.id == run_id do
    RunEvents.append_run_started(run)
    broadcast_run("agent.run.started", run)
    send(task_pid, {:run_started_ack, run.id})
    send(self(), :broadcast_status)
    {:noreply, %{state | active_run: %{active | run: run}}}
  end

  def handle_info(
        {:run_result, task_pid, run_id, result},
        %{active_run: %{task_pid: task_pid, task_ref: task_ref, run: %{id: run_id} = run}} =
          state
      ) do
    Process.demonitor(task_ref, [:flush])

    state =
      case result do
        {:ok, summary} -> complete_run(state, run, summary)
        {:error, reason} -> fail_run(state, run, error_message(reason))
      end

    send(self(), :drain)
    send(self(), :broadcast_status)
    {:noreply, %{state | active_run: nil}}
  end

  def handle_info({:run_result, _task_pid, _run_id, _result}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, task_ref, :process, _task_pid, reason},
        %{active_run: %{task_ref: task_ref, run: run}} = state
      ) do
    state = fail_run(state, run, "run task exited: #{error_message(reason)}")
    send(self(), :drain)
    send(self(), :broadcast_status)
    {:noreply, %{state | active_run: nil}}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _task_pid, reason},
        %{recovery_task_ref: task_ref} = state
      ) do
    error = "recovery task exited: #{error_message(reason)}"

    new_state = %{
      state
      | ready: true,
        recovery_task_ref: nil,
        recovery_error: error,
        last_error: error
    }

    broadcast_status(new_state)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp execute_run(daemon, run, timeout) do
    result =
      with {:ok, session} <- create_session(run),
           :ok <- Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}"),
           {:ok, running} <- Runs.mark_running(run, %{session_id: session.id}),
           :ok <- announce_started(daemon, running),
           :ok <- Sessions.send_message(session.id, run.prompt) do
        await_session(session.id, timeout, [])
      end

    send(daemon, {:run_result, self(), run.id, result})
  end

  defp recover_runs(queue_capacity) do
    with {:ok, running} <- Runs.list_by_status_result("running", limit: :all),
         {:ok, waiting} <- Runs.list_by_status_result("waiting_approval", limit: :all),
         {:ok, interrupted} <- interrupt_runs(running ++ waiting),
         {:ok, queued} <- Runs.list_by_status_result("queued", limit: :all) do
      queued = Enum.sort_by(queued, & &1.inserted_at, {:asc, DateTime})
      {recoverable, overflow} = Enum.split(queued, queue_capacity)

      case fail_recovery_overflow(overflow) do
        :ok -> {:ok, interrupted, recoverable}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp interrupt_runs(runs) do
    results = Enum.map(runs, &Runs.mark_interrupted(&1, "daemon_restarted"))

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, run} -> run end)}
      {:error, reason} -> {:error, {:recovery_interrupt_failed, reason}}
    end
  end

  defp fail_recovery_overflow(runs) do
    case Enum.find_value(runs, fn run ->
           case Runs.mark_failed(run, "queue capacity exceeded during daemon recovery") do
             {:ok, failed} ->
               RunEvents.append_run_failed(failed)
               broadcast_run("agent.run.failed", failed, %{error: failed.error})
               nil

             {:error, reason} ->
               reason
           end
         end) do
      nil -> :ok
      reason -> {:error, {:recovery_overflow_failed, reason}}
    end
  end

  defp start_task(task_supervisor, fun) do
    Task.Supervisor.start_child(task_supervisor, fun)
  catch
    :exit, reason -> {:error, reason}
  end

  defp cancel_owned_run(state, run_id) do
    cond do
      state.active_run && state.active_run.run.id == run_id ->
        cancel_active_run(state)

      true ->
        case take_queued_run(state.queue, run_id) do
          {:ok, run, queue} -> cancel_queued_run(state, run, queue)
          :error -> cancel_unowned_run(run_id)
        end
    end
  end

  defp cancel_active_run(state) do
    %{run: run, task_pid: task_pid, task_ref: task_ref} = state.active_run
    durable_run = Runs.get(run.id) || run

    case Runs.mark_cancelled(durable_run) do
      {:ok, cancelled} ->
        if is_binary(cancelled.session_id), do: Sessions.cancel(cancelled.session_id)

        Process.demonitor(task_ref, [:flush])
        _ = Task.Supervisor.terminate_child(state.task_supervisor, task_pid)
        RunEvents.append_run_cancelled(cancelled)
        broadcast_run("agent.run.cancelled", cancelled)
        {:ok, cancelled, %{state | active_run: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_queued_run(state, run, queue) do
    case Runs.mark_cancelled(run) do
      {:ok, cancelled} ->
        RunEvents.append_run_cancelled(cancelled)
        broadcast_run("agent.run.cancelled", cancelled)
        {:ok, cancelled, %{state | queue: queue}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_unowned_run(run_id) do
    case Runs.get(run_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ~w(completed failed cancelled interrupted) ->
        {:error, :terminal}

      _run ->
        {:error, :not_owned}
    end
  end

  defp take_queued_run(queue, run_id) do
    runs = :queue.to_list(queue)

    case Enum.split_while(runs, &(&1.id != run_id)) do
      {_before, []} -> :error
      {before, [run | after_runs]} -> {:ok, run, :queue.from_list(before ++ after_runs)}
    end
  end

  defp create_session(run) do
    opts =
      %{
        agent: run.assistant_name || "main",
        provider: run.provider,
        model: run.model,
        title: "Agent run #{run.id}"
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Sessions.create(run.assistant_name || "main", opts)
  end

  defp announce_started(daemon, run) do
    send(daemon, {:run_started, self(), run})

    receive do
      {:run_started_ack, run_id} when run_id == run.id -> :ok
    after
      5_000 -> {:error, :daemon_start_ack_timeout}
    end
  end

  defp await_session(session_id, timeout, chunks) do
    receive do
      {"text_delta", %{text: text}} when is_binary(text) ->
        await_session(session_id, timeout, [text | chunks])

      {"done", _payload} ->
        {:ok, final_summary(session_id, chunks)}

      {"error", payload} ->
        {:error, session_error(payload)}

      {"session_status", %{status: "error"} = payload} ->
        {:error, session_error(payload)}

      {"session_status", %{status: "idle"}} ->
        {:ok, final_summary(session_id, chunks)}

      _other ->
        await_session(session_id, timeout, chunks)
    after
      timeout -> {:error, :session_timeout}
    end
  end

  defp final_summary(session_id, chunks) do
    durable_summary =
      session_id
      |> Sessions.get_messages()
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{role: "assistant", parts: parts} ->
          parts
          |> Enum.flat_map(fn
            %Synapsis.Part.Text{content: content} when is_binary(content) -> [content]
            _other -> []
          end)
          |> Enum.join("")
          |> case do
            "" -> nil
            text -> text
          end

        _other ->
          nil
      end)

    durable_summary || fallback_summary(chunks)
  end

  defp fallback_summary([]), do: "(no assistant response)"
  defp fallback_summary(chunks), do: chunks |> Enum.reverse() |> Enum.join()

  defp complete_run(state, run, summary) do
    case Runs.mark_completed(run, summary) do
      {:ok, completed} ->
        RunEvents.append_run_completed(completed)
        broadcast_run("agent.run.completed", completed)
        %{state | last_error: nil}

      {:error, reason} ->
        %{state | last_error: "could not complete run #{run.id}: #{inspect(reason)}"}
    end
  end

  defp fail_run(state, run, error) do
    case Runs.mark_failed(run, error) do
      {:ok, failed} ->
        RunEvents.append_run_failed(failed)
        broadcast_run("agent.run.failed", failed, %{error: error})
        %{state | last_error: error}

      {:error, reason} ->
        %{state | last_error: "could not fail run #{run.id}: #{inspect(reason)}"}
    end
  end

  defp public_status(state) do
    queued_ids = state.queue |> :queue.to_list() |> Enum.map(& &1.id)
    active = state.active_run && run_summary(state.active_run.run)

    %{
      ready: state.ready,
      active_run: active,
      active_run_id: active && active.id,
      queued_count: length(queued_ids),
      queued_ids: queued_ids,
      last_error: state.last_error,
      recovery_error: state.recovery_error
    }
  end

  defp run_summary(run) do
    %{
      id: run.id,
      kind: run.kind,
      status: run.status,
      assistant_name: run.assistant_name,
      session_id: run.session_id,
      provider: run.provider,
      model: run.model,
      started_at: run.started_at
    }
  end

  defp broadcast_run(event, run, payload \\ %{}) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event,
       %{
         event: event,
         run_id: run.id,
         kind: run.kind,
         status: run.status,
         payload: payload,
         at: DateTime.utc_now()
       }}
    )
  end

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event,
       %{event: "agent.daemon.status", status: public_status(state), at: DateTime.utc_now()}}
    )
  end

  defp validate_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "", do: {:error, :invalid_prompt}, else: :ok
  end

  defp validate_prompt(_prompt), do: {:error, :invalid_prompt}

  defp validate_options(opts) do
    invalid_string? =
      Enum.any?(@string_options, fn key ->
        case option(opts, key) do
          nil -> false
          value when is_binary(value) -> String.trim(value) == ""
          _other -> true
        end
      end)

    cond do
      invalid_string? -> {:error, :invalid_options}
      not is_map(option(opts, :metadata, %{})) -> {:error, :invalid_options}
      true -> {:ok, opts}
    end
  end

  defp option(opts, key, default \\ nil) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp configured_capacity(config) do
    config |> Keyword.get(:queue_capacity, @default_queue_capacity) |> valid_capacity()
  end

  defp valid_capacity(capacity) when is_integer(capacity) and capacity > 0, do: capacity
  defp valid_capacity(_capacity), do: @default_queue_capacity

  defp session_error(%{message: message}) when is_binary(message), do: message
  defp session_error(%{"message" => message}) when is_binary(message), do: message
  defp session_error(%{reason: reason}), do: error_message(reason)
  defp session_error(reason), do: error_message(reason)

  defp error_message(%Ecto.Changeset{}), do: "invalid run attributes"
  defp error_message(reason) when is_binary(reason), do: String.slice(reason, 0, 500)

  defp error_message(reason) do
    reason |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500)
  end
end
