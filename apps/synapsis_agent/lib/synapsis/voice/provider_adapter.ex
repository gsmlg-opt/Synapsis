defmodule Synapsis.Voice.ProviderAdapter do
  @moduledoc "Presents exactly one Realtime response to the native Conversation."
  @behaviour Backplane.AgentRuntime.ConversationAdapter

  @terminal [:response_completed, :response_interrupted, :response_failed]

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

    event =
      case GenServer.call(session, {:response, ref, request, instructions}, 10_000) do
        :ok -> nil
        :offline -> %{type: :response_interrupted, reason: "media_unavailable"}
        {:error, _} -> failure("Realtime response was not dispatched")
      end

    %{session: session, ref: ref, monitor: monitor, event: event, done: false}
  catch
    :exit, _ ->
      %{event: failure("Voice session unavailable"), done: false}
  end

  defp next(%{done: true} = state), do: {:halt, state}
  defp next(%{event: event} = state) when is_map(event), do: {[event], %{state | done: true}}

  defp next(%{ref: ref, monitor: monitor} = state) do
    receive do
      {:voice_response, ^ref, event} ->
        {[event], %{state | done: event.type in @terminal}}

      {:DOWN, ^monitor, :process, _, _} ->
        {[failure("Voice session unavailable")], %{state | done: true}}
    after
      180_000 -> {[failure("Realtime response timed out")], %{state | done: true}}
    end
  end

  defp close(%{session: session, ref: ref, monitor: monitor}) do
    GenServer.cast(session, {:retire_response, ref})
    Process.demonitor(monitor, [:flush])
  end

  defp close(_), do: :ok

  defp failure(message), do: %{type: :response_failed, error: message}
end
