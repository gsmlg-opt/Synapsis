defmodule Synapsis.Agent.Daemon.Execution do
  @moduledoc false

  @topic "agent:daemon"
  @max_option_length 255
  @max_error_length 500
  @string_options ~w(assistant_name provider model source tool_profile)a
  @terminal_statuses ~w(completed failed cancelled interrupted)

  def manual_attrs(prompt, opts) when is_map(opts) do
    with :ok <- validate_prompt(prompt), :ok <- validate_options(opts) do
      {:ok,
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
       }}
    end
  end

  def manual_attrs(prompt, _opts) do
    with :ok <- validate_prompt(prompt), do: {:error, :invalid_options}
  end

  def status(state) do
    queued_ids = state.queue |> :queue.to_list() |> Enum.map(& &1.id)
    active = state.active_run && active_summary(state.active_run)

    %{
      ready: state.ready,
      active_run: active,
      active_run_id: active && active.id,
      queued_count: length(queued_ids),
      queued_ids: queued_ids,
      recovery_backlog_count: Map.get(state, :recovery_backlog_count, 0),
      last_error: bound_optional(state.last_error),
      recovery_error: bound_optional(state.recovery_error)
    }
  end

  def persist_submission(deps, attrs, :create), do: create_submission(deps, attrs)

  def persist_submission(deps, attrs, :reconcile) do
    case deps.runs.fetch(attrs.id) do
      {:ok, %{status: "queued"} = run} -> submission_persisted(deps, run)
      {:ok, run} -> {:error, {:unexpected_submission_status, run.status}}
      :not_found -> create_submission(deps, attrs)
      {:error, reason} -> {:retry, {:submission_read_failed, reason}}
    end
  end

  def run(daemon, deps, task_supervisor, run, timeout, cleanup_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      case start_inner(daemon, deps, task_supervisor, run) do
        {:ok, inner_pid, inner_ref} ->
          case await_inner(inner_pid, inner_ref, deadline, run, nil) do
            {:result, outcome, current_run, session_id} ->
              cleanup_errors =
                if match?({:error, _reason}, outcome) do
                  bounded_session_cleanup(
                    task_supervisor,
                    deps.sessions,
                    session_id,
                    cleanup_timeout
                  )
                else
                  []
                end

              finalize(deps, current_run, outcome, session_id)
              |> add_errors(cleanup_errors)

            {:timeout, current_run, session_id} ->
              stop_process(inner_pid)

              cleanup_errors =
                bounded_session_cleanup(
                  task_supervisor,
                  deps.sessions,
                  session_id,
                  cleanup_timeout
                )

              finalize(deps, current_run, {:error, :session_timeout}, session_id)
              |> add_errors(cleanup_errors)

            {:exit, reason, current_run, session_id} ->
              cleanup_errors =
                bounded_session_cleanup(
                  task_supervisor,
                  deps.sessions,
                  session_id,
                  cleanup_timeout
                )

              finalize(
                deps,
                current_run,
                {:error, "run task exited: #{bounded_error(reason)}"},
                session_id
              )
              |> add_errors(cleanup_errors)
          end

        {:error, reason} ->
          finalize(deps, run, {:error, {:inner_task_start_failed, reason}}, nil)
      end

    send(daemon, {:runner_result, self(), run.id, result})
  end

  def finalize(deps, run, {:ok, summary}, session_id) do
    finalize_transition(deps, run, :completed, fn ->
      deps.runs.mark_completed(run, summary, %{session_id: session_id})
    end)
  end

  def finalize(deps, run, {:error, reason}, session_id) do
    error = bounded_error(reason)

    finalize_transition(deps, run, :failed, fn ->
      deps.runs.mark_failed(run, error, %{session_id: session_id})
    end)
  end

  def finalize_crashed_outer(deps, task_supervisor, active, reason, cleanup_timeout) do
    stop_process(active.inner_pid)

    cleanup_errors =
      bounded_session_cleanup(
        task_supervisor,
        deps.sessions,
        active.session_id,
        cleanup_timeout
      )

    current_run = fetch_current(deps.runs, active.run)

    finalize(
      deps,
      current_run,
      {:error, "run task exited: #{bounded_error(reason)}"},
      active.session_id
    )
    |> add_errors(cleanup_errors)
  end

  def cancel_active(deps, task_supervisor, active, cleanup_timeout) do
    {session_id, preparation_errors} = prepare_active_cancel(active, cleanup_timeout)

    result =
      with {:ok, run} <- fetch_owned(deps.runs, active.run.id),
           {:ok, cancelled} <-
             deps.runs.mark_cancelled(run, %{session_id: session_id || run.session_id}) do
        errors =
          preparation_errors ++
            bounded_session_cleanup(
              task_supervisor,
              deps.sessions,
              cancelled.session_id,
              cleanup_timeout
            ) ++
            collect_errors([
              fn -> append_event(deps, :cancelled, cancelled) end,
              fn -> publish_run("agent.run.cancelled", cancelled) end
            ])

        {:ok, cancelled, errors}
      else
        {:error, reason} ->
          case terminal_or_error(deps.runs, active.run.id, reason) do
            {:ok, terminal, errors} ->
              {:ok, terminal, preparation_errors ++ errors}

            {:error, persistence_reason} ->
              cleanup_errors =
                bounded_session_cleanup(
                  task_supervisor,
                  deps.sessions,
                  session_id,
                  cleanup_timeout
                )

              {:degraded, persistence_reason, active.run, preparation_errors ++ cleanup_errors}
          end
      end

    stop_process(active.inner_pid)
    stop_process(active.task_pid)
    result
  end

  defp prepare_active_cancel(%{task_pid: task_pid} = active, timeout)
       when is_pid(task_pid) do
    ref = make_ref()
    send(task_pid, {:prepare_cancel, self(), ref})

    receive do
      {:cancel_prepared, ^ref, session_id} -> {session_id || active.session_id, []}
    after
      timeout ->
        stop_process(active.inner_pid)
        {active.session_id, [bounded_error(:cancel_prepare_timeout)]}
    end
  end

  defp prepare_active_cancel(active, _timeout) do
    stop_process(active.inner_pid)
    {active.session_id, []}
  end

  def cancel_queued(deps, run) do
    case deps.runs.mark_cancelled(run) do
      {:ok, cancelled} ->
        errors =
          collect_errors([
            fn -> append_event(deps, :cancelled, cancelled) end,
            fn -> publish_run("agent.run.cancelled", cancelled) end
          ])

        {:ok, cancelled, errors}

      {:error, reason} ->
        terminal_or_error(deps.runs, run.id, reason)
    end
  end

  def classify(runs, run_id) do
    case runs.fetch(run_id) do
      :not_found -> {:error, :not_found}
      {:ok, %{status: status}} when status in @terminal_statuses -> {:error, :terminal}
      {:ok, _run} -> {:error, :not_owned}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_task(task_supervisor, fun) do
    Task.Supervisor.start_child(task_supervisor, fun)
  catch
    :exit, reason -> {:error, reason}
  end

  def start_monitored_task(task_supervisor, fun) do
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

  def protect(fun) do
    fun.()
  rescue
    error -> {:error, {:task_exception, error}}
  catch
    kind, reason -> {:error, {:task_exit, kind, reason}}
  end

  def publish_status(status) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event,
       %{event: "agent.daemon.status", status: status, at: DateTime.utc_now()}}
    )
  end

  def append_event(deps, event, run) do
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

  def publish_run(event, run, payload \\ %{}) do
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

  def bounded_error(%Ecto.Changeset{}), do: "invalid run attributes"
  def bounded_error(reason) when is_binary(reason), do: String.slice(reason, 0, @max_error_length)

  def bounded_error(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_error_length)
    |> String.slice(0, @max_error_length)
  end

  def valid_capacity(capacity, _default) when is_integer(capacity) and capacity > 0, do: capacity
  def valid_capacity(_capacity, default), do: default

  defp create_submission(deps, attrs) do
    case deps.runs.create(attrs) do
      {:ok, run} -> submission_persisted(deps, run)
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:retry, {:submission_write_failed, reason}}
    end
  end

  defp submission_persisted(deps, run) do
    errors =
      collect_errors([
        fn -> append_event(deps, :created, run) end,
        fn -> publish_run("agent.run.queued", run) end
      ])

    {:ok, run, errors}
  end

  defp start_inner(daemon, deps, task_supervisor, run) do
    outer = self()
    token = make_ref()

    with {:ok, pid} <-
           start_task(task_supervisor, fn ->
             Process.link(outer)

             receive do
               {:start_inner, ^token} ->
                 send(outer, {:inner_started, self()})
                 send(daemon, {:runner_inner, outer, run.id, self()})

                 {outcome, current_run, session_id} =
                   execute_session(outer, daemon, deps, run)

                 send(outer, {:inner_result, self(), outcome, current_run, session_id})
             end
           end) do
      ref = Process.monitor(pid)
      send(pid, {:start_inner, token})
      {:ok, pid, ref}
    end
  end

  defp await_inner(inner_pid, inner_ref, deadline, current_run, session_id) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:inner_started, ^inner_pid} ->
        await_inner(inner_pid, inner_ref, deadline, current_run, session_id)

      {:inner_session_created, ^inner_pid, created_session_id} ->
        await_inner(inner_pid, inner_ref, deadline, current_run, created_session_id)

      {:inner_running, ^inner_pid, running} ->
        await_inner(inner_pid, inner_ref, deadline, running, session_id)

      {:inner_result, ^inner_pid, outcome, result_run, result_session_id} ->
        Process.unlink(inner_pid)
        Process.demonitor(inner_ref, [:flush])
        {:result, outcome, result_run, result_session_id || session_id}

      {:prepare_cancel, cancel_task, cancel_ref} ->
        Process.unlink(inner_pid)
        Process.demonitor(inner_ref, [:flush])
        stop_process(inner_pid)

        {current_run, session_id} =
          drain_inner_progress(inner_pid, current_run, session_id)

        send(cancel_task, {:cancel_prepared, cancel_ref, session_id})
        await_cancel_termination(deadline, current_run, session_id)

      {:DOWN, ^inner_ref, :process, ^inner_pid, reason} ->
        Process.unlink(inner_pid)
        {:exit, reason, current_run, session_id}
    after
      remaining ->
        Process.unlink(inner_pid)
        Process.demonitor(inner_ref, [:flush])
        {:timeout, current_run, session_id}
    end
  end

  defp drain_inner_progress(inner_pid, current_run, session_id) do
    receive do
      {:inner_session_created, ^inner_pid, created_session_id} ->
        drain_inner_progress(inner_pid, current_run, created_session_id)

      {:inner_running, ^inner_pid, running} ->
        drain_inner_progress(inner_pid, running, session_id)

      {:inner_result, ^inner_pid, _outcome, result_run, result_session_id} ->
        drain_inner_progress(inner_pid, result_run, result_session_id || session_id)
    after
      0 -> {current_run, session_id}
    end
  end

  defp await_cancel_termination(deadline, current_run, session_id) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      _message -> await_cancel_termination(deadline, current_run, session_id)
    after
      remaining -> {:timeout, current_run, session_id}
    end
  end

  defp execute_session(outer, daemon, deps, run) do
    case create_session(deps.sessions, run) do
      {:ok, session} ->
        send(outer, {:inner_session_created, self(), session.id})
        send(daemon, {:session_created, outer, run.id, session.id})

        outcome =
          with :ok <- Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}"),
               {:ok, running} <- deps.runs.mark_running(run, %{session_id: session.id}),
               :ok <- append_event(deps, :started, running),
               :ok <- publish_run("agent.run.started", running),
               :ok <- announce_running(outer, daemon, running),
               :ok <- deps.sessions.send_message(session.id, run.prompt) do
            {await_session(deps.sessions, session.id, []), running}
          else
            {:error, reason} -> {{:error, reason}, fetch_current(deps.runs, run)}
          end

        {result, current_run} = outcome
        {result, current_run, session.id}

      {:error, reason} ->
        {{:error, reason}, fetch_current(deps.runs, run), nil}
    end
  end

  defp announce_running(outer, daemon, run) do
    send(outer, {:inner_running, self(), run})
    send(daemon, {:runner_started, outer, run})
    :ok
  end

  defp finalize_transition(deps, original_run, event, transition) do
    case transition.() do
      {:ok, terminal_run} ->
        errors =
          collect_errors([
            fn -> append_event(deps, event, terminal_run) end,
            fn ->
              publish_run(
                "agent.run.#{event}",
                terminal_run,
                terminal_payload(event, terminal_run)
              )
            end
          ])

        {:ok, terminal_run, errors}

      {:error, reason} ->
        case terminal_run(deps.runs, original_run.id) do
          {:ok, terminal} -> {:ok, terminal, [bounded_error(reason)]}
          _other -> {:error, {:terminal_persistence_failed, reason}, original_run}
        end
    end
  end

  defp terminal_or_error(runs, run_id, reason) do
    case terminal_run(runs, run_id) do
      {:ok, terminal} -> {:ok, terminal, [bounded_error(reason)]}
      _other -> {:error, reason}
    end
  end

  defp terminal_run(runs, run_id) do
    case runs.fetch(run_id) do
      {:ok, %{status: status} = run} when status in @terminal_statuses -> {:ok, run}
      _other -> :error
    end
  end

  defp fetch_owned(runs, run_id) do
    case runs.fetch(run_id) do
      {:ok, run} -> {:ok, run}
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_current(runs, fallback) do
    case runs.fetch(fallback.id) do
      {:ok, run} -> run
      _other -> fallback
    end
  end

  defp await_session(sessions, session_id, chunks) do
    receive do
      {"text_delta", %{text: text}} when is_binary(text) ->
        await_session(sessions, session_id, [text | chunks])

      {"done", _payload} ->
        {:ok, final_summary(sessions, session_id, chunks)}

      {"error", payload} ->
        {:error, session_error(payload)}

      {"session_status", %{status: "error"} = payload} ->
        {:error, session_error(payload)}

      {"session_status", %{status: "idle"}} ->
        {:ok, final_summary(sessions, session_id, chunks)}

      _other ->
        await_session(sessions, session_id, chunks)
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

  defp bounded_session_cleanup(_task_supervisor, _sessions, nil, _timeout), do: []

  defp bounded_session_cleanup(task_supervisor, sessions, session_id, timeout) do
    bounded_cleanup(task_supervisor, timeout, fn -> sessions.cancel(session_id) end)
  end

  defp bounded_cleanup(task_supervisor, timeout, function) do
    task = Task.Supervisor.async_nolink(task_supervisor, fn -> protect(function) end)

    case Task.yield(task, timeout) do
      {:ok, :ok} ->
        []

      {:ok, {:ok, _value}} ->
        []

      {:ok, {:error, reason}} ->
        [bounded_error(reason)]

      {:ok, other} ->
        [bounded_error({:unexpected_cleanup_result, other})]

      {:exit, reason} ->
        [bounded_error({:cleanup_task_exit, reason})]

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        [bounded_error(:cleanup_timeout)]
    end
  catch
    :exit, reason -> [bounded_error({:cleanup_task_start_failed, reason})]
  end

  defp stop_process(nil), do: :ok

  defp stop_process(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    :ok
  end

  defp collect_errors(functions) do
    Enum.flat_map(functions, fn function ->
      case protect(function) do
        :ok -> []
        {:ok, _value} -> []
        {:error, reason} -> [bounded_error(reason)]
        other -> [bounded_error({:unexpected_cleanup_result, other})]
      end
    end)
  end

  defp add_errors({:ok, run, errors}, extra), do: {:ok, run, errors ++ extra}
  defp add_errors(error, _extra), do: error

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

  defp active_summary(active) do
    run = active.run

    %{
      id: run.id,
      kind: run.kind,
      status: run.status,
      assistant_name: bound_optional(run.assistant_name, @max_option_length),
      session_id: active.session_id || run.session_id,
      provider: bound_optional(run.provider, @max_option_length),
      model: bound_optional(run.model, @max_option_length),
      started_at: run.started_at,
      phase: active.phase,
      degraded: active.degraded,
      error: bound_optional(active.error)
    }
  end

  defp validate_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "", do: {:error, :invalid_prompt}, else: :ok
  end

  defp validate_prompt(_prompt), do: {:error, :invalid_prompt}

  defp validate_options(opts) do
    invalid? =
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
      invalid? -> {:error, :invalid_options}
      not is_map(option(opts, :metadata, %{})) -> {:error, :invalid_options}
      true -> :ok
    end
  end

  defp option(opts, key, default \\ nil),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))

  defp bound_optional(value, max \\ @max_error_length)
  defp bound_optional(nil, _max), do: nil
  defp bound_optional(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp bound_optional(value, max), do: value |> inspect() |> String.slice(0, max)
end
