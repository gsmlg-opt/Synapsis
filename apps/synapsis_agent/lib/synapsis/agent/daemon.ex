defmodule Synapsis.Agent.Daemon do
  @moduledoc """
  Permanently supervised FIFO coordinator for durable manual agent runs.

  The GenServer owns only queue and monitor state. Store, event, PubSub, and
  session work runs in unlinked tasks under `RunTaskSupervisor`.
  """

  use GenServer

  alias Synapsis.Agent.{RunEvents, Runs}
  alias Synapsis.AgentRun
  alias Synapsis.Sessions

  @topic "agent:daemon"
  @task_supervisor Synapsis.Agent.Daemon.RunTaskSupervisor
  @queue_capacity 25
  @run_timeout :timer.minutes(30)
  @max_option_length 255
  @max_error_length 500
  @string_options ~w(assistant_name provider model source tool_profile)a
  @terminal_statuses ~w(completed failed cancelled interrupted)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def topic, do: @topic
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def submit(prompt, opts \\ %{}), do: submit(__MODULE__, prompt, opts)

  def submit(server, prompt, opts) when is_map(opts) do
    with :ok <- validate_prompt(prompt), {:ok, opts} <- validate_options(opts) do
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
      cancelling_ids: MapSet.new(),
      pending: %{},
      queue_capacity:
        opts
        |> Keyword.get(:queue_capacity, Keyword.get(config, :queue_capacity, @queue_capacity))
        |> valid_capacity(),
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
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:submit, prompt, opts}, from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, :not_ready}, state}

      queue_load(state) >= state.queue_capacity ->
        {:reply, {:error, :queue_full}, state}

      true ->
        attrs = run_attrs(prompt, opts)

        case start_operation(state, %{type: :submit, from: from}, fn ->
               submit_run(state.deps, attrs)
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

        case start_operation(state, op, fn -> cancel_active(state, active) end) do
          {:ok, state} ->
            active = %{active | cancelling: true}
            {:noreply, %{state | active_run: active}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      {:queued, run} ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :queued}

        case start_operation(state, op, fn -> cancel_queued(state, run) end) do
          {:ok, state} ->
            {:noreply, %{state | cancelling_ids: MapSet.put(state.cancelling_ids, run_id)}}

          {:error, reason} ->
            {:reply, {:error, reason}, put_error(state, reason)}
        end

      :unknown ->
        op = %{type: :cancel, from: from, run_id: run_id, location: :unknown}

        case start_operation(state, op, fn -> classify_unowned(state.deps.runs, run_id) end) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:reply, {:error, reason}, put_error(state, reason)}
        end
    end
  end

  @impl true
  def handle_info(:recover, state) do
    case start_operation(state, %{type: :recovery}, fn -> recover_runs(state.deps) end) do
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
    error = bounded_error(reason)
    new_state = %{state | ready: true, recovery_error: error, last_error: error}
    dispatch_status(new_state)
    {:noreply, new_state}
  end

  defp handle_runner_result({:ok, terminal_run}, _active, state) do
    last_error =
      if terminal_run.status == "failed", do: bounded_error(terminal_run.error), else: nil

    new_state = %{state | active_run: nil, last_error: last_error}
    dispatch_status(new_state)
    send(self(), :drain)
    {:noreply, new_state}
  end

  defp handle_runner_result({:error, reason, run}, active, state) do
    error = bounded_error(reason)

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
    error = "run task exited: #{bounded_error(reason)}"

    case start_finalizer(state, active.run, {:error, error}) do
      {:ok, task_pid, task_ref} ->
        active = %{active | task_pid: task_pid, task_ref: task_ref, phase: :finalizing}
        {:noreply, %{state | active_run: active}}

      {:error, start_reason} ->
        error = bounded_error({:finalizer_task_start_failed, start_reason})

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
        error = bounded_error({:operation_task_exit, reason})
        GenServer.reply(from, {:error, error})

        state =
          %{state | pending: pending}
          |> Map.update!(:cancelling_ids, &MapSet.delete(&1, Map.get(op, :run_id)))
          |> maybe_reset_cancelling(op)
          |> put_error(error)

        {:noreply, state}

      {%{type: :recovery}, pending} ->
        error = bounded_error({:recovery_task_exit, reason})

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

    case start_monitored_task(state.task_supervisor, fn ->
           result = protect(fun)
           send(daemon, {:operation_result, self(), result})
         end) do
      {:ok, pid, ref} ->
        {:ok, %{state | pending: Map.put(state.pending, ref, Map.put(op, :pid, pid))}}

      {:error, reason} ->
        {:error, {:task_start_failed, bounded_error(reason)}}
    end
  end

  defp start_runner(state, run) do
    daemon = self()

    with {:ok, pid, ref} <-
           start_monitored_task(state.task_supervisor, fn ->
             run_and_finalize(daemon, state.deps, run, state.run_timeout)
           end) do
      {:ok, pid, ref}
    end
  end

  defp start_finalizer(state, run, result) do
    daemon = self()

    with {:ok, pid, ref} <-
           start_monitored_task(state.task_supervisor, fn ->
             terminal =
               case protect(fn -> finalize_run(state.deps, run, result) end) do
                 {:error, reason} -> {:error, reason, run}
                 terminal -> terminal
               end

             send(daemon, {:runner_result, self(), run.id, terminal})
           end) do
      {:ok, pid, ref}
    end
  end

  defp submit_run(deps, attrs) do
    case deps.runs.create(attrs) do
      {:ok, run} ->
        _ = append_event(deps, :created, run)
        _ = publish_run("agent.run.queued", run)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_and_finalize(daemon, deps, run, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      with {:ok, session} <- create_session(deps.sessions, run),
           :ok <- Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}"),
           {:ok, running} <- deps.runs.mark_running(run, %{session_id: session.id}),
           :ok <- append_event(deps, :started, running),
           :ok <- publish_run("agent.run.started", running),
           :ok <- announce_started(daemon, running),
           :ok <- deps.sessions.send_message(session.id, run.prompt) do
        {await_session(deps.sessions, session.id, deadline, []), running}
      else
        {:error, reason} -> {{:error, reason}, deps.runs.get(run.id) || run}
      end

    {outcome, current_run} = result
    terminal = finalize_run(deps, current_run, outcome)
    send(daemon, {:runner_result, self(), run.id, terminal})
  end

  defp finalize_run(deps, run, {:ok, summary}) do
    finalize_transition(deps, run, :completed, fn -> deps.runs.mark_completed(run, summary) end)
  end

  defp finalize_run(deps, run, {:error, reason}) do
    error = bounded_error(reason)
    finalize_transition(deps, run, :failed, fn -> deps.runs.mark_failed(run, error) end)
  end

  defp finalize_transition(deps, original_run, event, transition) do
    case transition.() do
      {:ok, terminal_run} ->
        with :ok <- append_event(deps, event, terminal_run),
             :ok <-
               publish_run(
                 "agent.run.#{event}",
                 terminal_run,
                 terminal_payload(event, terminal_run)
               ) do
          {:ok, terminal_run}
        else
          {:error, reason} -> {:error, {:terminal_event_failed, reason}, terminal_run}
        end

      {:error, reason} ->
        {:error, {:terminal_persistence_failed, reason}, original_run}
    end
  end

  defp cancel_active(state, active) do
    deps = state.deps
    run = deps.runs.get(active.run.id) || active.run

    with {:ok, cancelled} <- deps.runs.mark_cancelled(run),
         :ok <- append_event(deps, :cancelled, cancelled),
         :ok <- publish_run("agent.run.cancelled", cancelled),
         :ok <- maybe_cancel_session(deps.sessions, cancelled.session_id),
         :ok <- terminate_runner(state.task_supervisor, active.task_pid) do
      {:ok, cancelled}
    end
  end

  defp cancel_queued(state, run) do
    deps = state.deps

    with {:ok, cancelled} <- deps.runs.mark_cancelled(run),
         :ok <- append_event(deps, :cancelled, cancelled),
         :ok <- publish_run("agent.run.cancelled", cancelled) do
      {:ok, cancelled}
    end
  end

  defp classify_unowned(runs, run_id) do
    case runs.get(run_id) do
      nil -> {:error, :not_found}
      %{status: status} when status in @terminal_statuses -> {:error, :terminal}
      _run -> {:error, :not_owned}
    end
  end

  defp recover_runs(deps) do
    {running, running_errors} = load_status(deps.runs, "running")
    {waiting, waiting_errors} = load_status(deps.runs, "waiting_approval")
    {queued, queued_errors} = load_status(deps.runs, "queued")

    {interrupted, interrupt_errors} =
      Enum.reduce(running ++ waiting, {[], []}, fn run, {ok, errors} ->
        case deps.runs.mark_interrupted(run, "daemon_restarted") do
          {:ok, interrupted} ->
            _ = append_event(deps, :interrupted, interrupted)
            _ = publish_run("agent.run.interrupted", interrupted, %{reason: "daemon_restarted"})
            {[interrupted | ok], errors}

          {:error, reason} ->
            {ok, [{run.id, reason} | errors]}
        end
      end)

    queued = Enum.sort_by(queued, & &1.inserted_at, {:asc, DateTime})
    errors = running_errors ++ waiting_errors ++ queued_errors ++ interrupt_errors
    {:ok, Enum.reverse(interrupted), queued, errors}
  end

  defp load_status(runs, status) do
    case runs.list_by_status_result(status, limit: :all) do
      {:ok, found} -> {found, []}
      {:error, reason} -> {[], [{status, reason}]}
    end
  end

  defp await_session(sessions, session_id, deadline, chunks) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :session_timeout}
    else
      receive do
        {"text_delta", %{text: text}} when is_binary(text) ->
          await_session(sessions, session_id, deadline, [text | chunks])

        {"done", _payload} ->
          {:ok, final_summary(sessions, session_id, chunks)}

        {"error", payload} ->
          {:error, session_error(payload)}

        {"session_status", %{status: "error"} = payload} ->
          {:error, session_error(payload)}

        {"session_status", %{status: "idle"}} ->
          {:ok, final_summary(sessions, session_id, chunks)}

        _other ->
          await_session(sessions, session_id, deadline, chunks)
      after
        remaining -> {:error, :session_timeout}
      end
    end
  end

  defp final_summary(sessions, session_id, chunks) do
    durable =
      session_id
      |> sessions.get_messages()
      |> Enum.reverse()
      |> Enum.find_value(&assistant_text/1)

    durable ||
      if(chunks == [],
        do: "(no assistant response)",
        else: chunks |> Enum.reverse() |> Enum.join()
      )
  end

  defp assistant_text(%{role: "assistant", parts: parts}) do
    parts
    |> Enum.flat_map(fn
      %Synapsis.Part.Text{content: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp assistant_text(_message), do: nil

  defp create_session(sessions, run) do
    opts =
      %{
        agent: run.assistant_name || "main",
        provider: run.provider,
        model: run.model,
        title: "Agent run #{run.id}"
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    sessions.create(run.assistant_name || "main", opts)
  end

  defp announce_started(daemon, run) do
    send(daemon, {:runner_started, self(), run})

    receive do
      {:runner_started_ack, run_id} when run_id == run.id -> :ok
    after
      5_000 -> {:error, :daemon_start_ack_timeout}
    end
  end

  defp append_event(deps, event, run) do
    function = String.to_existing_atom("append_run_#{event}")

    case apply(deps.run_events, function, [run]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> :ok
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp publish_run(event, run, payload \\ %{}) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event,
       %{
         event: event,
         run_id: run.id,
         kind: run.kind,
         status: run.status,
         payload: bound_payload(payload),
         at: DateTime.utc_now()
       }}
    )
  end

  defp dispatch_status(state) do
    status = public_status(state)

    _ =
      start_task(state.task_supervisor, fn ->
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          @topic,
          {:agent_daemon_event,
           %{event: "agent.daemon.status", status: status, at: DateTime.utc_now()}}
        )
      end)

    :ok
  end

  defp public_status(state) do
    queued_ids = state.queue |> :queue.to_list() |> Enum.map(& &1.id)
    active = state.active_run && active_summary(state.active_run)

    %{
      ready: state.ready,
      active_run: active,
      active_run_id: active && active.id,
      queued_count: length(queued_ids),
      queued_ids: queued_ids,
      last_error: bound_optional(state.last_error),
      recovery_error: bound_optional(state.recovery_error)
    }
  end

  defp active_summary(active) do
    run = active.run

    %{
      id: run.id,
      kind: run.kind,
      status: run.status,
      assistant_name: bound_optional(run.assistant_name, @max_option_length),
      session_id: run.session_id,
      provider: bound_optional(run.provider, @max_option_length),
      model: bound_optional(run.model, @max_option_length),
      started_at: run.started_at,
      phase: active.phase,
      degraded: active.degraded,
      error: bound_optional(active.error)
    }
  end

  defp run_attrs(prompt, opts) do
    %{
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

  defp maybe_cancel_session(_sessions, nil), do: :ok
  defp maybe_cancel_session(sessions, session_id), do: sessions.cancel(session_id)
  defp terminate_runner(_task_supervisor, nil), do: :ok

  defp terminate_runner(task_supervisor, pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_task(task_supervisor, fun) do
    Task.Supervisor.start_child(task_supervisor, fun)
  catch
    :exit, reason -> {:error, reason}
  end

  defp start_monitored_task(task_supervisor, fun) do
    token = make_ref()

    with {:ok, pid} <-
           start_task(task_supervisor, fn ->
             receive do
               {:start, ^token} -> fun.()
             end
           end) do
      ref = Process.monitor(pid)
      send(pid, {:start, token})
      {:ok, pid, ref}
    end
  end

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, {:task_exception, error}}
  catch
    kind, reason -> {:error, {:task_exit, kind, reason}}
  end

  defp terminal_payload(:failed, run), do: %{error: bounded_error(run.error)}
  defp terminal_payload(_event, _run), do: %{}

  defp bound_payload(payload) do
    Map.new(payload, fn
      {key, value} when is_binary(value) -> {key, String.slice(value, 0, @max_error_length)}
      pair -> pair
    end)
  end

  defp session_error(%{message: message}) when is_binary(message), do: message
  defp session_error(%{"message" => message}) when is_binary(message), do: message
  defp session_error(%{reason: reason}), do: bounded_error(reason)
  defp session_error(reason), do: bounded_error(reason)

  defp put_error(state, reason), do: %{state | last_error: bounded_error(reason)}

  defp join_errors([]), do: nil
  defp join_errors(errors), do: bounded_error({:recovery_partial_failure, errors})

  defp bounded_error(%Ecto.Changeset{}), do: "invalid run attributes"

  defp bounded_error(reason) when is_binary(reason),
    do: String.slice(reason, 0, @max_error_length)

  defp bounded_error(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_error_length)
    |> String.slice(0, @max_error_length)
  end

  defp bound_optional(value, max \\ @max_error_length)
  defp bound_optional(nil, _max), do: nil
  defp bound_optional(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp bound_optional(value, max), do: value |> inspect() |> String.slice(0, max)

  defp validate_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "", do: {:error, :invalid_prompt}, else: :ok
  end

  defp validate_prompt(_prompt), do: {:error, :invalid_prompt}

  defp validate_options(opts) do
    invalid_string? =
      Enum.any?(@string_options, fn key ->
        case option(opts, key) do
          nil ->
            false

          value when is_binary(value) ->
            String.trim(value) == "" or String.length(value) > @max_option_length

          _other ->
            true
        end
      end)

    cond do
      invalid_string? -> {:error, :invalid_options}
      not is_map(option(opts, :metadata, %{})) -> {:error, :invalid_options}
      true -> {:ok, opts}
    end
  end

  defp option(opts, key, default \\ nil),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))

  defp valid_capacity(capacity) when is_integer(capacity) and capacity > 0, do: capacity
  defp valid_capacity(_capacity), do: @queue_capacity
end
