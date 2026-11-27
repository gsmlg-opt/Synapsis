defmodule Synapsis.Voice.ProviderAdapter do
  @moduledoc "Presents exactly one Realtime response to the native Conversation."
  @behaviour Backplane.AgentRuntime.ConversationAdapter

  @terminal [:response_completed, :response_interrupted, :response_failed]
  # Keep transport deadlines inside Conversation's 30s idle / 180s total
  # deadlines so the media owner can retire the correlated attempt first.
  @idle_timeout 25_000
  @total_timeout 165_000
  @retirement_timeout 2_000

  @impl true
  def stream(request, %{voice_session: session, request_options: options}) do
    Stream.resource(
      fn -> subscribe(session, request, options.system_prompt) end,
      &next/1,
      &close/1
    )
  end

  defp subscribe(session, request, instructions) do
    ref = make_ref()
    monitor = Process.monitor(session)
    deadline = System.monotonic_time(:millisecond) + @total_timeout
    idle = Application.get_env(:synapsis_agent, :voice_response_idle_timeout, @idle_timeout)

    event =
      case GenServer.call(session, {:response, ref, request, instructions}, 10_000) do
        :ok -> nil
        :offline -> %{type: :response_interrupted, reason: "media_unavailable"}
        {:error, _} -> failure("Realtime response was not dispatched")
      end

    %{
      session: session,
      ref: ref,
      monitor: monitor,
      event: event,
      done: false,
      retiring: false,
      deadline: deadline,
      idle: idle
    }
  catch
    :exit, _ ->
      %{event: failure("Voice session unavailable"), done: false}
  end

  defp next(%{done: true} = state), do: {:halt, state}
  defp next(%{event: event} = state) when is_map(event), do: {[event], %{state | done: true}}

  defp next(%{ref: ref, monitor: monitor} = state) do
    timeout = min(state.idle, state.deadline - System.monotonic_time(:millisecond))

    if timeout <= 0 do
      timeout_response(state)
    else
      receive do
        {:voice_response, ^ref, event} ->
          {[event], %{state | done: event.type in @terminal}}

        {:DOWN, ^monitor, :process, _, _} ->
          {[failure("Voice session unavailable")], %{state | done: true}}
      after
        timeout -> timeout_response(state)
      end
    end
  end

  defp timeout_response(%{retiring: true} = state),
    do: {[failure("Realtime response retirement was not confirmed")], %{state | done: true}}

  defp timeout_response(state) do
    # Let the media owner settle the race with a terminal event already
    # received from Realtime. It owns the attempt and the transport together.
    GenServer.cast(state.session, {:retire_response, state.ref, :realtime_response_timeout})

    next(%{
      state
      | retiring: true,
        deadline: System.monotonic_time(:millisecond) + @retirement_timeout,
        idle: @retirement_timeout
    })
  end

  defp close(%{session: session, ref: ref, monitor: monitor}) do
    GenServer.cast(session, {:retire_response, ref})
    Process.demonitor(monitor, [:flush])
  end

  defp close(_), do: :ok

  defp failure(message), do: %{type: :response_failed, error: message}
end
