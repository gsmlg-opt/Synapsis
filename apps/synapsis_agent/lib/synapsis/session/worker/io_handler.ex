defmodule Synapsis.Session.Worker.IOHandler do
  @moduledoc """
  Handles async I/O events for Worker: streams, tools, auditor.

  Every handler takes the worker data struct and returns the updated struct.
  The owning process shell (the `:gen_statem` Worker, or GlobalAgent's
  GenServer) wraps the result in its own behaviour return shape — handlers
  stay process-agnostic.
  """

  require Logger

  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.Worker.{Auditor, Checkpoint, Persistence}
  alias Synapsis.Agent.{StreamAccumulator, ResponseFlusher}
  alias Synapsis.Session.Worker

  def handle_start_stream(request, state) do
    provider = state.agent[:provider] || state.session.provider
    config = Map.put(state.provider_config, :session_id, state.session_id)
    debug_handler = maybe_attach_debug(state)

    case start_stream(request, config, provider, state) do
      {:ok, ref} ->
        %{
          state
          | stream_ref: ref,
            stream_acc: StreamAccumulator.new(),
            debug_handler_id: debug_handler
        }

      {:error, reason} ->
        detach_debug(debug_handler)
        new_ctx = Map.put(state.engine_ctx, :stream_error, reason)
        Worker.step_engine(%{state | engine_ctx: new_ctx})
    end
  end

  defp start_stream(request, config, provider, %Worker{}) do
    SessionStream.start_stream(request, config, provider, forward_to: self())
  end

  defp start_stream(request, config, provider, _state) do
    SessionStream.start_stream(request, config, provider)
  end

  def handle_dispatch_tools(classified, opts, state) do
    epoch = state.epoch
    caller = self()

    # Idempotency: skip any tool already executed in this turn (soft-retry guard).
    fresh =
      Enum.reject(classified, fn {_cls, tu} ->
        MapSet.member?(state.executed_tool_ids, tu.tool_use_id)
      end)

    {task_map, hashes, new_executed} =
      Enum.reduce(
        fresh,
        {%{}, opts[:tool_call_hashes] || MapSet.new(), state.executed_tool_ids},
        fn {_cls, tool_use} = item, {acc_map, acc_hashes, acc_exec} ->
          new_hash = MapSet.put(acc_hashes, :erlang.phash2({tool_use.tool, tool_use.input}))
          task = spawn_fenced_tool_task(item, caller, epoch, opts, state)
          # Map ref → tool_use_id so handle_tool_task_down can flush an error result on crash.
          map2 = if task, do: Map.put(acc_map, task.ref, tool_use.tool_use_id), else: acc_map
          exec2 = MapSet.put(acc_exec, tool_use.tool_use_id)
          {map2, new_hash, exec2}
        end
      )

    %{
      state
      | pending_tool_count: length(fresh),
        stream_acc: Map.put(state.stream_acc, :tool_call_hashes, hashes),
        tool_tasks: Map.merge(state.tool_tasks, task_map),
        executed_tool_ids: new_executed
    }
  end

  def handle_start_auditor(params, state) do
    task = Auditor.start_async(params, state)
    Process.monitor(task.pid)
    state
  end

  def handle_provider_chunk(event, state) do
    if state.stream_ref do
      {broadcasts, new_acc} = StreamAccumulator.accumulate(event, state.stream_acc)

      for {name, payload} <- broadcasts,
          do: Persistence.broadcast(state.session_id, name, payload)

      %{state | stream_acc: new_acc}
    else
      state
    end
  end

  def handle_provider_done(state) do
    detach_debug(state.debug_handler_id)
    {_broadcasts, stream_acc} = StreamAccumulator.accumulate(:done, state.stream_acc)
    new_ctx = Map.put(state.engine_ctx, :stream_acc, stream_acc)

    Worker.step_engine(%{state | stream_ref: nil, debug_handler_id: nil, engine_ctx: new_ctx})
  end

  def handle_provider_error(reason, state) do
    detach_debug(state.debug_handler_id)
    Logger.warning("provider_error", session_id: state.session_id, reason: inspect(reason))
    new_ctx = Map.put(state.engine_ctx, :stream_error, reason)

    Worker.step_engine(%{state | stream_ref: nil, debug_handler_id: nil, engine_ctx: new_ctx})
  end

  # Worker-only (GlobalAgent has no checkpoint stack): a stream-guard
  # violation rolls back to the last checkpoint and resumes from the restored
  # engine node. The rule arrives pre-redacted from the adapter, so logging
  # it leaks nothing.
  def handle_stream_violation({:stream_violation, rule} = reason, state) do
    detach_debug(state.debug_handler_id)
    Logger.warning("stream_guard_violation", session_id: state.session_id, rule: inspect(rule))
    state = %{state | stream_ref: nil, debug_handler_id: nil}

    case state.checkpoints do
      [_ | _] ->
        case Checkpoint.rollback(state, "stream guard violation (#{inspect(rule)})") do
          {:ok, new_state, _checkpoint} ->
            Worker.step_engine(new_state)

          {:error, rollback_error} ->
            Logger.warning("checkpoint_rollback_failed",
              session_id: state.session_id,
              reason: inspect(rollback_error)
            )

            stream_error(state, reason)
        end

      [] ->
        stream_error(state, reason)
    end
  end

  defp stream_error(state, reason) do
    new_ctx = Map.put(state.engine_ctx, :stream_error, reason)
    Worker.step_engine(%{state | engine_ctx: new_ctx})
  end

  def handle_tool_result(id, result, is_error, state) do
    ResponseFlusher.flush_tool_result(state.session_id, id, result, is_error)

    Persistence.broadcast(state.session_id, "tool_result", %{
      tool_use_id: id,
      content: result,
      is_error: is_error
    })

    remaining = state.pending_tool_count - 1

    if remaining <= 0 do
      Worker.step_engine(%{state | pending_tool_count: 0})
    else
      %{state | pending_tool_count: remaining}
    end
  end

  def handle_tool_task_down(ref, tool_use_id, reason, state) do
    new_tool_tasks = Map.delete(state.tool_tasks, ref)

    if reason == :normal do
      # Task sent its {:tool_result, ...} message before exiting cleanly — nothing to do.
      %{state | tool_tasks: new_tool_tasks}
    else
      Logger.warning("tool_task_down",
        session_id: state.session_id,
        tool_use_id: tool_use_id,
        reason: inspect(reason)
      )

      # Flush an error tool_result so the provider never sees an unanswered tool_use.
      ResponseFlusher.flush_tool_result(
        state.session_id,
        tool_use_id,
        "Tool execution failed unexpectedly: #{inspect(reason)}",
        true
      )

      Persistence.broadcast(state.session_id, "tool_result", %{
        tool_use_id: tool_use_id,
        content: "Tool execution failed unexpectedly: #{inspect(reason)}",
        is_error: true
      })

      remaining = state.pending_tool_count - 1

      if remaining <= 0 do
        Worker.step_engine(%{state | pending_tool_count: 0, tool_tasks: new_tool_tasks})
      else
        %{state | pending_tool_count: remaining, tool_tasks: new_tool_tasks}
      end
    end
  end

  # --- QueryLoop event handlers ---

  def handle_query_loop_event({:stream_start}, state), do: state

  def handle_query_loop_event({:stream_chunk, chunk}, state) do
    case chunk do
      {:text_delta, text} ->
        Persistence.broadcast(state.session_id, "text_delta", %{text: text})

      {:tool_use_start, name, id} ->
        Persistence.broadcast(state.session_id, "tool_use", %{tool: name, tool_use_id: id})

      _ ->
        :ok
    end

    state
  end

  def handle_query_loop_event({:stream_end, _assistant_msg}, state), do: state

  def handle_query_loop_event({:tool_start, id, name, input}, state) do
    Persistence.broadcast(state.session_id, "tool_start", %{
      tool_use_id: id,
      tool: name,
      input: input
    })

    state
  end

  def handle_query_loop_event({:tool_result, id, result}, state) do
    Persistence.broadcast(state.session_id, "tool_result", %{
      tool_use_id: id,
      content: result.content,
      is_error: result.is_error
    })

    state
  end

  def handle_query_loop_event({:turn_complete, _turn}, state), do: state

  def handle_query_loop_event({:terminal, reason, _final_state}, state) do
    status = if reason == :completed, do: "idle", else: "error"
    Persistence.update_session_status(state.session_id, status)

    Persistence.broadcast(state.session_id, "session_status", %{
      status: status,
      reason: to_string(reason)
    })

    state
  end

  def handle_query_loop_event(_event, state), do: state

  # --- Private ---

  defp spawn_fenced_tool_task({classification, tool_use}, caller, epoch, opts, state) do
    case classification do
      cls when cls in [:approved, :auto_approved] ->
        project_path = opts[:project_path]
        effective_path = opts[:effective_path] || project_path
        session_id = opts[:session_id]
        agent_id = opts[:agent_id] || "default"
        tool_call_hashes = opts[:tool_call_hashes] || MapSet.new()
        call_hash = :erlang.phash2({tool_use.tool, tool_use.input})
        is_duplicate = MapSet.member?(tool_call_hashes, call_hash)

        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          try do
            result =
              Synapsis.Tool.Executor.execute_approved(tool_use.tool, tool_use.input, %{
                project_path: effective_path,
                session_id: session_id,
                working_dir: effective_path,
                agent_id: agent_id,
                agent_scope: :agent
              })

            {output, is_error} =
              case result do
                {:ok, out} ->
                  suffix =
                    if is_duplicate,
                      do:
                        "\n\nWarning: This exact tool call was already made in this conversation turn. Try a different approach.",
                      else: ""

                  {out <> suffix, false}

                {:error, reason} ->
                  {tool_error_message(reason), true}

                other ->
                  Logger.warning("tool_unexpected_result",
                    tool: tool_use.tool,
                    result: inspect(other)
                  )

                  {"Unexpected tool result: #{inspect(other)}", true}
              end

            send(caller, {:tool_result, epoch, tool_use.tool_use_id, output, is_error})
          rescue
            e ->
              Logger.warning("tool_task_crashed",
                tool: tool_use.tool,
                error: Exception.message(e)
              )

              send(
                caller,
                {:tool_result, epoch, tool_use.tool_use_id,
                 "Tool execution crashed: #{Exception.message(e)}", true}
              )
          catch
            kind, reason ->
              Logger.warning("tool_task_caught", tool: tool_use.tool, kind: kind)

              send(
                caller,
                {:tool_result, epoch, tool_use.tool_use_id,
                 "Tool execution failed: #{inspect({kind, reason})}", true}
              )
          end
        end)

      :requires_approval ->
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{state.session_id}",
          {"permission_request",
           %{
             tool: tool_use.tool,
             tool_use_id: tool_use.tool_use_id,
             input: tool_use.input
           }}
        )

        nil

      :denied ->
        ResponseFlusher.flush_tool_result(
          state.session_id,
          tool_use.tool_use_id,
          "Tool denied by permission policy.",
          true
        )

        nil
    end
  end

  defp tool_error_message(:timeout), do: "Tool execution timed out"
  defp tool_error_message(reason) when is_binary(reason), do: reason
  defp tool_error_message(_), do: "Tool execution failed"

  defp maybe_attach_debug(state) do
    if session_debug_enabled?(state.session_id) do
      Synapsis.Session.DebugTelemetry.attach(state.session_id)
    end
  end

  defp detach_debug(nil), do: :ok
  defp detach_debug(handler_id), do: Synapsis.Session.DebugTelemetry.detach(handler_id)

  defp session_debug_enabled?(session_id) do
    case Synapsis.Session.Store.get_meta(session_id) do
      {:ok, %{debug: true}} -> true
      _ -> false
    end
  end
end
