defmodule Synapsis.Session.Worker.IOHandler do
  @moduledoc "Handles async I/O events for Worker: streams, tools, auditor."

  require Logger

  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.Worker.{Auditor, Persistence}
  alias Synapsis.Agent.{StreamAccumulator, ResponseFlusher, ToolDispatcher}
  alias Synapsis.Agent.Runtime.Runner

  def handle_start_stream(request, state) do
    provider = state.agent[:provider] || state.session.provider

    # Inject session_id for telemetry/debug capture
    config = Map.put(state.provider_config, :session_id, state.session_id)
    debug_handler = maybe_attach_debug(state)

    case SessionStream.start_stream(request, config, provider) do
      {:ok, ref} ->
        {:noreply,
         %{
           state
           | stream_ref: ref,
             stream_acc: StreamAccumulator.new(),
             debug_handler_id: debug_handler
         }}

      {:error, reason} ->
        detach_debug(debug_handler)
        safe_resume(state.runner_pid, %{stream_error: reason})
        {:noreply, state}
    end
  end

  def handle_dispatch_tools(classified, opts, state) do
    hashes = ToolDispatcher.dispatch_all(classified, self(), state.session_id, opts)

    {:noreply,
     %{
       state
       | pending_tool_count: length(classified),
         stream_acc: Map.put(state.stream_acc, :tool_call_hashes, hashes)
     }}
  end

  def handle_start_auditor(params, state) do
    task = Auditor.start_async(params, state)
    Process.monitor(task.pid)
    {:noreply, state}
  end

  def handle_provider_chunk(event, state) do
    {broadcasts, new_acc} = StreamAccumulator.accumulate(event, state.stream_acc)
    for {name, payload} <- broadcasts, do: Persistence.broadcast(state.session_id, name, payload)
    {:noreply, %{state | stream_acc: new_acc}}
  end

  def handle_provider_done(state) do
    detach_debug(state.debug_handler_id)
    safe_resume(state.runner_pid, %{stream_acc: state.stream_acc})
    {:noreply, %{state | stream_ref: nil, debug_handler_id: nil}}
  end

  def handle_provider_error(reason, state) do
    detach_debug(state.debug_handler_id)
    Logger.warning("provider_error", session_id: state.session_id, reason: inspect(reason))
    safe_resume(state.runner_pid, %{stream_error: reason})
    {:noreply, %{state | stream_ref: nil, debug_handler_id: nil}}
  end

  def handle_tool_result(id, result, is_error, state) do
    ResponseFlusher.flush_tool_result(state.session_id, id, result, is_error)

    Persistence.broadcast(state.session_id, "tool_result", %{
      tool_use_id: id,
      content: result,
      is_error: is_error
    })

    remaining = state.pending_tool_count - 1
    if remaining <= 0, do: safe_resume(state.runner_pid, %{tools_completed: true})
    {:noreply, %{state | pending_tool_count: remaining}}
  end

  def handle_runner_exit(reason, state) do
    Logger.warning("runner_exited", session_id: state.session_id, reason: inspect(reason))
    Persistence.update_session_status(state.session_id, "error")
    Persistence.broadcast(state.session_id, "error", %{message: "Agent runner crashed"})
    Persistence.broadcast(state.session_id, "session_status", %{status: "error"})
    {:noreply, %{state | runner_pid: nil}}
  end

  # After cancel, runner_pid is nil but in-flight messages may still arrive.
  defp safe_resume(nil, _ctx), do: :ok
  defp safe_resume(pid, ctx), do: Runner.resume(pid, ctx)

  # -- Debug telemetry helpers --

  defp maybe_attach_debug(state) do
    if session_debug_enabled?(state.session_id) do
      Synapsis.Session.DebugTelemetry.attach(state.session_id)
    end
  end

  defp detach_debug(nil), do: :ok

  defp detach_debug(handler_id) do
    Synapsis.Session.DebugTelemetry.detach(handler_id)
  end

  defp session_debug_enabled?(session_id) do
    case Synapsis.Repo.get(Synapsis.Session, session_id) do
      %{debug: true} -> true
      _ -> false
    end
  end
end
