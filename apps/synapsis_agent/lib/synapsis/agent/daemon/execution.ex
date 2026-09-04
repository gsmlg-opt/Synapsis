defmodule Synapsis.Agent.Daemon.Execution do
  @moduledoc false

  alias Synapsis.Agent.RunEvents
  alias Synapsis.Agent.Daemon.Toolsets

  @max_option_length 255
  @max_error_length 500
  @string_options ~w(assistant_name provider model source tool_profile)a
  @terminal_statuses ~w(completed failed cancelled interrupted)
  @daemon_permission %{
    mode: :autonomous,
    allow_read: :allow,
    allow_write: :allow,
    allow_execute: :allow,
    allow_destructive: :deny,
    tool_overrides: %{}
  }

  def manual_attrs(prompt, opts) when is_map(opts) do
    with :ok <- validate_prompt(prompt), :ok <- validate_options(opts) do
      {:ok,
       %{
         kind: "manual",
         status: "queued",
         source: option(opts, :source, "web"),
         assistant_name: option(opts, :assistant_name, "main"),
         prompt: prompt,
         tool_profile: option(opts, :tool_profile, "assistant_basic"),
         provider: option(opts, :provider),
         model: option(opts, :model),
         metadata: option(opts, :metadata, %{})
       }}
    end
  end

  def manual_attrs(prompt, _opts) do
    with :ok <- validate_prompt(prompt), do: {:error, :invalid_options}
  end

  def heartbeat_attrs(opts) when is_map(opts) do
    prompt = option(opts, :prompt)
    heartbeat_id = option(opts, :heartbeat_id)
    no_overlap = option(opts, :no_overlap, true)
    max_runtime_ms = option(opts, :max_runtime_ms, :timer.minutes(2))
    metadata = option(opts, :metadata, %{})

    with :ok <- validate_prompt(prompt),
         true <- is_binary(heartbeat_id) and match?({:ok, _}, Ecto.UUID.cast(heartbeat_id)),
         true <- is_boolean(no_overlap),
         true <- is_integer(max_runtime_ms) and max_runtime_ms > 0,
         true <- is_map(metadata),
         :ok <- validate_options(opts) do
      metadata =
        metadata
        |> Map.put("no_overlap", no_overlap)
        |> Map.put("max_runtime_ms", max_runtime_ms)

      {:ok,
       %{
         kind: "heartbeat",
         status: "queued",
         source: option(opts, :source, "system"),
         assistant_name: option(opts, :assistant_name, "main"),
         heartbeat_id: heartbeat_id,
         routine_id: option(opts, :routine_id, heartbeat_id),
         prompt: prompt,
         tool_profile: option(opts, :tool_profile, "assistant_basic"),
         provider: option(opts, :provider),
         model: option(opts, :model),
         metadata: metadata
       }}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  def heartbeat_attrs(_opts), do: {:error, :invalid_options}

  def run_timeout(%{metadata: metadata}, default) when is_map(metadata) do
    case Map.get(metadata, "max_runtime_ms", Map.get(metadata, :max_runtime_ms)) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> default
    end
  end

  def run_timeout(_run, default), do: default

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

  def persist_submission(deps, attrs, :create, task_supervisor, event_timeout),
    do: create_submission(deps, attrs, task_supervisor, event_timeout)

  def persist_submission(deps, attrs, :reconcile, task_supervisor, event_timeout) do
    case deps.runs.fetch(attrs.id) do
      {:ok, %{status: "queued"} = run} ->
        submission_persisted(deps, run, task_supervisor, event_timeout)

      {:ok, run} ->
        {:error, {:unexpected_submission_status, run.status}}

      :not_found ->
        create_submission(deps, attrs, task_supervisor, event_timeout)

      {:error, reason} ->
        {:retry, {:submission_read_failed, reason}}
    end
  end

  def run(daemon, deps, task_supervisor, run, timeout, cleanup_timeout, event_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    {current_run, outcome, session_id, warnings} =
      case start_inner(daemon, deps, task_supervisor, run, event_timeout) do
        {:ok, inner_pid, inner_ref} ->
          case await_inner(inner_pid, inner_ref, deadline, run, nil) do
            {:result, outcome, current_run, session_id, event_errors} ->
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

              {current_run, outcome, session_id, event_errors ++ cleanup_errors}

            {:timeout, current_run, session_id} ->
              stop_process(inner_pid)

              cleanup_errors =
                bounded_session_cleanup(
                  task_supervisor,
                  deps.sessions,
                  session_id,
                  cleanup_timeout
                )

              {current_run, {:error, :session_timeout}, session_id, cleanup_errors}

            {:exit, reason, current_run, session_id} ->
              cleanup_errors =
                bounded_session_cleanup(
                  task_supervisor,
                  deps.sessions,
                  session_id,
                  cleanup_timeout
                )

              {current_run, {:error, "run task exited: #{bounded_error(reason)}"}, session_id,
               cleanup_errors}
          end

        {:error, reason} ->
          {run, {:error, {:inner_task_start_failed, reason}}, nil, []}
      end

    :ok = announce_finalizing(daemon, run.id, current_run, outcome, session_id, warnings)

    result =
      finalize(deps, current_run, outcome, session_id, task_supervisor, event_timeout)
      |> add_errors(warnings)

    send(daemon, {:runner_result, self(), run.id, result})
  end

  defp announce_finalizing(daemon, run_id, run, outcome, session_id, warnings) do
    send(daemon, {:runner_finalizing, self(), run_id, run, outcome, session_id, warnings})

    receive do
      {:runner_finalizing_ack, ^run_id} -> :ok
    after
      5_000 -> :ok
    end
  end

  def finalize(deps, run, {:ok, summary}, session_id, task_supervisor, event_timeout) do
    finalize_transition(deps, run, :completed, task_supervisor, event_timeout, fn ->
      deps.runs.mark_completed(run, summary, %{session_id: session_id})
    end)
  end

  def finalize(deps, run, {:error, reason}, session_id, task_supervisor, event_timeout) do
    error = bounded_error(reason)

    finalize_transition(deps, run, :failed, task_supervisor, event_timeout, fn ->
      deps.runs.mark_failed(run, error, %{session_id: session_id})
    end)
  end

  def finalize_intent(deps, task_supervisor, event_timeout, intent) do
    finalize(
      deps,
      intent.run,
      intent.outcome,
      intent.session_id,
      task_supervisor,
      event_timeout
    )
    |> add_errors(intent.warnings)
  end

  def finalize_crashed_outer(
        deps,
        task_supervisor,
        active,
        reason,
        cleanup_timeout,
        event_timeout
      ) do
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
      active.session_id,
      task_supervisor,
      event_timeout
    )
    |> add_errors(cleanup_errors)
  end

  def cancel_active(deps, task_supervisor, active, cleanup_timeout, event_timeout) do
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
            emit_run_event(
              task_supervisor,
              event_timeout,
              deps,
              :cancelled,
              cancelled
            )

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

  def cancel_queued(deps, task_supervisor, event_timeout, run) do
    case deps.runs.mark_cancelled(run) do
      {:ok, cancelled} ->
        errors =
          emit_run_event(
            task_supervisor,
            event_timeout,
            deps,
            :cancelled,
            cancelled
          )

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

  def emit_run_event(
        task_supervisor,
        event_timeout,
        deps,
        event,
        run,
        payload \\ %{}
      ) do
    bounded_tasks(
      task_supervisor,
      event_timeout,
      [
        fn -> RunEvents.append_lifecycle(deps.run_events, event, run) end,
        fn -> RunEvents.publish_lifecycle(event, run, payload) end
      ],
      :event_timeout,
      :event_task_start_failed,
      :event_task_exit,
      :unexpected_event_result
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

  defp create_submission(deps, attrs, task_supervisor, event_timeout) do
    case deps.runs.create(attrs) do
      {:ok, run} -> submission_persisted(deps, run, task_supervisor, event_timeout)
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:retry, {:submission_write_failed, reason}}
    end
  end

  defp submission_persisted(deps, run, task_supervisor, event_timeout) do
    errors =
      emit_run_event(
        task_supervisor,
        event_timeout,
        deps,
        :created,
        run
      )

    {:ok, run, errors}
  end

  defp start_inner(daemon, deps, task_supervisor, run, event_timeout) do
    outer = self()
    token = make_ref()

    with {:ok, pid} <-
           start_task(task_supervisor, fn ->
             Process.link(outer)

             receive do
               {:start_inner, ^token} ->
                 send(outer, {:inner_started, self()})
                 send(daemon, {:runner_inner, outer, run.id, self()})

                 {outcome, current_run, session_id, event_errors} =
                   execute_session(
                     outer,
                     daemon,
                     deps,
                     task_supervisor,
                     event_timeout,
                     run
                   )

                 send(
                   outer,
                   {:inner_result, self(), outcome, current_run, session_id, event_errors}
                 )
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

      {:inner_result, ^inner_pid, outcome, result_run, result_session_id, event_errors} ->
        Process.unlink(inner_pid)
        Process.demonitor(inner_ref, [:flush])
        {:result, outcome, result_run, result_session_id || session_id, event_errors}

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

      {:inner_result, ^inner_pid, _outcome, result_run, result_session_id, _event_errors} ->
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

  defp execute_session(outer, daemon, deps, task_supervisor, event_timeout, run) do
    with {:ok, tool_names} <- Toolsets.resolve(run.tool_profile),
         {:ok, session} <- create_session(deps.sessions, run, tool_names) do
      permission = Map.get(deps, :permission, Synapsis.Tool.Permission)

      case permission.update_config(session.id, @daemon_permission) do
        {:ok, _permission} ->
          execute_configured_session(
            outer,
            daemon,
            deps,
            task_supervisor,
            event_timeout,
            run,
            session
          )

        {:error, reason} ->
          {{:error, {:permission_setup_failed, reason}}, fetch_current(deps.runs, run),
           session.id, []}
      end
    else
      {:error, reason} -> {{:error, reason}, fetch_current(deps.runs, run), nil, []}
    end
  end

  defp execute_configured_session(
         outer,
         daemon,
         deps,
         task_supervisor,
         event_timeout,
         run,
         session
       ) do
    send(outer, {:inner_session_created, self(), session.id})
    send(daemon, {:session_created, outer, run.id, session.id})

    outcome =
      with :ok <- Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}"),
           {:ok, running} <- deps.runs.mark_running(run, %{session_id: session.id}),
           event_errors =
             emit_run_event(
               task_supervisor,
               event_timeout,
               deps,
               :started,
               running
             ),
           :ok <- announce_running(outer, daemon, running, event_errors),
           :ok <- deps.sessions.send_message(session.id, run.prompt) do
        {await_session(deps.sessions, session.id, []), running, event_errors}
      else
        {:error, reason} -> {{:error, reason}, fetch_current(deps.runs, run), []}
      end

    {result, current_run, event_errors} = outcome
    {result, current_run, session.id, event_errors}
  end

  defp announce_running(outer, daemon, run, event_errors) do
    send(outer, {:inner_running, self(), run})
    send(daemon, {:runner_started, outer, run, event_errors})
    :ok
  end

  defp finalize_transition(
         deps,
         original_run,
         event,
         task_supervisor,
         event_timeout,
         transition
       ) do
    case transition.() do
      {:ok, terminal_run} ->
        errors =
          emit_run_event(
            task_supervisor,
            event_timeout,
            deps,
            event,
            terminal_run,
            %{}
          )

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

  defp create_session(sessions, run, tool_names) do
    opts =
      %{
        agent: run.assistant_name || "main",
        provider: run.provider,
        model: run.model,
        title: "Agent run #{run.id}",
        config: %{"daemon_run_tool_names" => tool_names}
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    sessions.create(run.assistant_name || "main", opts)
  end

  defp bounded_session_cleanup(_task_supervisor, _sessions, nil, _timeout), do: []

  defp bounded_session_cleanup(task_supervisor, sessions, session_id, timeout) do
    bounded_tasks(
      task_supervisor,
      timeout,
      [fn -> sessions.cancel(session_id) end],
      :cleanup_timeout,
      :cleanup_task_start_failed,
      :cleanup_task_exit,
      :unexpected_cleanup_result
    )
  end

  defp bounded_tasks(
         task_supervisor,
         timeout,
         functions,
         timeout_reason,
         start_error,
         exit_error,
         unexpected_error
       ) do
    deadline = System.monotonic_time(:millisecond) + timeout

    functions
    |> Enum.map(&start_bounded_task(task_supervisor, &1, start_error))
    |> Enum.flat_map(
      &await_bounded_task(
        &1,
        deadline,
        timeout_reason,
        exit_error,
        unexpected_error
      )
    )
  end

  defp start_bounded_task(task_supervisor, function, start_error) do
    {:ok, Task.Supervisor.async(task_supervisor, fn -> protect(function) end)}
  rescue
    error -> {:error, {start_error, error}}
  catch
    :exit, reason -> {:error, {start_error, reason}}
  end

  defp await_bounded_task({:error, reason}, _deadline, _timeout, _exit, _unexpected),
    do: [bounded_error(reason)]

  defp await_bounded_task(
         {:ok, task},
         deadline,
         timeout_reason,
         exit_error,
         unexpected_error
       ) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, remaining) do
      {:ok, :ok} ->
        []

      {:ok, {:ok, _value}} ->
        []

      {:ok, {:error, reason}} ->
        [bounded_error(reason)]

      {:ok, other} ->
        [bounded_error({unexpected_error, other})]

      {:exit, reason} ->
        [bounded_error({exit_error, reason})]

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        [bounded_error(timeout_reason)]
    end
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

  defp add_errors({:ok, run, errors}, extra), do: {:ok, run, errors ++ extra}
  defp add_errors(error, _extra), do: error

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
      invalid? ->
        {:error, :invalid_options}

      not is_map(option(opts, :metadata, %{})) ->
        {:error, :invalid_options}

      match?({:error, _reason}, Toolsets.resolve(option(opts, :tool_profile, "assistant_basic"))) ->
        {:error, :invalid_options}

      true ->
        :ok
    end
  end

  defp option(opts, key, default \\ nil),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))

  defp bound_optional(value, max \\ @max_error_length)
  defp bound_optional(nil, _max), do: nil
  defp bound_optional(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp bound_optional(value, max), do: value |> inspect() |> String.slice(0, max)
end
