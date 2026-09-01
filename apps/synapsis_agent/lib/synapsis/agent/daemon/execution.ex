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

  def submit(deps, attrs) do
    case deps.runs.create(attrs) do
      {:ok, run} ->
        _ = append_event(deps, :created, run)
        _ = publish_run("agent.run.queued", run)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reconcile_submit(deps, run_id) do
    case deps.runs.get(run_id) do
      %{status: "queued"} = run ->
        _ = append_event(deps, :created, run)
        _ = publish_run("agent.run.queued", run)
        {:ok, run}

      nil ->
        {:error, :submission_not_persisted}

      run ->
        {:error, {:unexpected_submission_status, run.status}}
    end
  end

  def run(daemon, deps, run, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    {outcome, current_run, session_id} = execute_session(daemon, deps, run, deadline)

    cleanup_errors =
      if match?({:error, _reason}, outcome),
        do: collect_errors([fn -> maybe_cancel_session(deps.sessions, session_id) end]),
        else: []

    terminal = finalize(deps, current_run, outcome, session_id) |> add_errors(cleanup_errors)
    send(daemon, {:runner_result, self(), run.id, terminal})
  end

  def finalize(deps, run, outcome), do: finalize(deps, run, outcome, run.session_id)

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

  def cancel_active(deps, task_supervisor, active) do
    run = deps.runs.get(active.run.id) || active.run

    case deps.runs.mark_cancelled(run, %{session_id: active.session_id || run.session_id}) do
      {:ok, cancelled} ->
        errors =
          collect_errors([
            fn -> append_event(deps, :cancelled, cancelled) end,
            fn -> publish_run("agent.run.cancelled", cancelled) end,
            fn -> maybe_cancel_session(deps.sessions, cancelled.session_id) end,
            fn -> terminate_runner(task_supervisor, active.task_pid) end
          ])

        {:ok, cancelled, errors}

      {:error, reason} ->
        {:error, reason}
    end
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
        {:error, reason}
    end
  end

  def timeout(deps, task_supervisor, active) do
    cleanup_errors =
      collect_errors([
        fn -> maybe_cancel_session(deps.sessions, active.session_id) end,
        fn -> terminate_runner(task_supervisor, active.task_pid) end
      ])

    run = deps.runs.get(active.run.id) || active.run

    finalize(deps, run, {:error, :session_timeout}, active.session_id)
    |> add_errors(cleanup_errors)
  end

  def classify(runs, run_id) do
    case runs.get(run_id) do
      nil -> {:error, :not_found}
      %{status: status} when status in @terminal_statuses -> {:error, :terminal}
      _run -> {:error, :not_owned}
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

  defp execute_session(daemon, deps, run, deadline) do
    case create_session(deps.sessions, run) do
      {:ok, session} ->
        outcome =
          with :ok <- announce_session_created(daemon, run.id, session.id),
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

        {result, current_run} = outcome
        {result, current_run, session.id}

      {:error, reason} ->
        {{:error, reason}, deps.runs.get(run.id) || run, nil}
    end
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
        {:error, {:terminal_persistence_failed, reason}, original_run}
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

  defp announce_session_created(daemon, run_id, session_id) do
    send(daemon, {:session_created, self(), run_id, session_id})

    receive do
      {:session_created_ack, ^run_id} -> :ok
    after
      5_000 -> {:error, :daemon_session_ack_timeout}
    end
  end

  defp announce_started(daemon, run) do
    send(daemon, {:runner_started, self(), run})

    receive do
      {:runner_started_ack, run_id} when run_id == run.id -> :ok
    after
      5_000 -> {:error, :daemon_start_ack_timeout}
    end
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
