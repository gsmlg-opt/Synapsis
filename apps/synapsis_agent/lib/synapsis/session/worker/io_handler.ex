defmodule Synapsis.Session.Worker.IOHandler do
  @moduledoc "Handles async I/O events for Worker: streams, tools, auditor."

  require Logger

  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.Worker.{Auditor, Persistence}
  alias Synapsis.Agent.{StreamAccumulator, ResponseFlusher, ToolDispatcher}
  alias Synapsis.Agent.Runtime.Runner

  def handle_start_stream(request, state) do
    provider = state.agent[:provider] || state.session.provider

    case SessionStream.start_stream(request, state.provider_config, provider) do
      {:ok, ref} ->
        {:noreply, %{state | stream_ref: ref, stream_acc: StreamAccumulator.new()}}

      {:error, reason} ->
        Runner.resume(state.runner_pid, %{stream_error: reason})
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
    Runner.resume(state.runner_pid, %{stream_acc: state.stream_acc})
    {:noreply, %{state | stream_ref: nil}}
  end

  def handle_provider_error(reason, state) do
    Logger.warning("provider_error", session_id: state.session_id, reason: inspect(reason))
    Runner.resume(state.runner_pid, %{stream_error: reason})
    {:noreply, %{state | stream_ref: nil}}
  end

  def handle_tool_result(id, result, is_error, state) do
    ResponseFlusher.flush_tool_result(state.session_id, id, result, is_error)

    Persistence.broadcast(state.session_id, "tool_result", %{
      tool_use_id: id,
      content: result,
      is_error: is_error
    })

    remaining = state.pending_tool_count - 1
    if remaining <= 0, do: Runner.resume(state.runner_pid, %{tools_completed: true})
    {:noreply, %{state | pending_tool_count: remaining}}
  end

  def handle_runner_exit(reason, state) do
    Logger.warning("runner_exited", session_id: state.session_id, reason: inspect(reason))
    Persistence.update_session_status(state.session_id, "error")
    Persistence.broadcast(state.session_id, "error", %{message: "Agent runner crashed"})
    Persistence.broadcast(state.session_id, "session_status", %{status: "error"})
    {:noreply, %{state | runner_pid: nil}}
  end
end
