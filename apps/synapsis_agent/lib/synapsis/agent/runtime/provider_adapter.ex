defmodule Synapsis.Agent.Runtime.ProviderAdapter do
  @moduledoc """
  Lazy Backplane conversation stream over the existing Synapsis HTTP adapter.

  Trusted context requires `:provider_config`, `:request_options`, and `:tools`.
  Atom-keyed request options carry model/system instructions. Provider-state
  affinity is derived from the same config used by the host stream decoder.
  Optional `:stream_timeout` (default 30s) is an absolute attempt deadline and
  `:output_limit` (default 1 MiB) bounds accumulated host event bytes. This adapter
  is not yet wired into session or daemon dispatch.

  A dedicated supervised relay isolates untagged provider messages, monitors its
  consumer, and owns a linked provider task. Early halt, timeout, consumer death,
  or abnormal relay termination stops the provider task as well.
  """
  @behaviour Backplane.AgentRuntime.ConversationAdapter

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.Runtime.{ProviderEvents, ProviderMessages}
  alias Synapsis.Provider.Adapter

  @impl true
  def stream(request, context) do
    Stream.resource(fn -> start(request, context) end, &next/1, &close/1)
  end

  defp start(request, context) do
    owner = self()
    token = make_ref()
    timeout = Map.get(context, :stream_timeout, 30_000)
    limit = Map.get(context, :output_limit, 1_048_576)

    if is_integer(timeout) and timeout > 0 and is_integer(limit) and limit > 0 do
      task =
        Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
          relay(owner, token, request, context, timeout, limit)
        end)

      %{task: task, token: token, done: false, deadline: now() + timeout}
    else
      %{
        error: Error.new(:validation, "Stream timeout and output limit must be positive integers")
      }
    end
  end

  defp next(%{done: true} = state), do: {:halt, state}
  defp next(%{error: error} = state), do: {[failed(error)], Map.put(state, :done, true)}

  defp next(state) do
    if now() >= state.deadline,
      do: {[failed(Error.new(:timeout, "Provider attempt timed out"))], %{state | done: true}},
      else: receive_event(state)
  end

  defp receive_event(%{task: task, token: token} = state) do
    receive do
      {__MODULE__, ^token, event} ->
        {[event], %{state | done: event.type in [:response_completed, :response_failed]}}

      {ref, _result} when ref == task.ref ->
        next(state)

      {:DOWN, ref, :process, _, _reason} when ref == task.ref ->
        {[failed(Error.new(:execution_failure, "Provider relay ended without a terminal event"))],
         %{state | done: true}}
    after
      max(state.deadline - now(), 0) ->
        {[failed(Error.new(:timeout, "Provider attempt timed out"))], %{state | done: true}}
    end
  end

  defp close(%{task: task, token: token}) do
    Task.shutdown(task, :brutal_kill)
    flush(token)
  end

  defp close(_), do: :ok

  defp relay(owner, token, request, context, timeout, limit) do
    owner_ref = Process.monitor(owner)
    deadline = now() + timeout
    config = Map.fetch!(context, :provider_config)

    options =
      context
      |> Map.fetch!(:request_options)
      |> Map.put(:provider_type, config[:type] || config["type"])
      |> Map.put(:base_url, config[:base_url] || config["base_url"])
      |> Map.put(:endpoint, config[:base_url] || config["base_url"])
      |> Map.put(
        :provider_name,
        config[:provider_name] || config["provider_name"] || config[:name] || config["name"]
      )
      |> Map.put(:account, config[:account] || config["account"])
      |> Map.put(:workspace, config[:workspace] || config["workspace"])

    with {:ok, messages} <- ProviderMessages.to_host(request.messages),
         {:ok, wire} <- Adapter.format_request(messages, Map.fetch!(context, :tools), options),
         {:ok, handle} <- Adapter.stream(wire, config, link: true) do
      try do
        emit(
          owner,
          token,
          Map.merge(
            Map.take(
              request,
              [:run_id, :incarnation, :turn_id, :step_id, :attempt_id]
            ),
            %{type: :response_started}
          )
        )

        forward(owner, owner_ref, token, handle, ProviderEvents.new(), deadline, limit)
      after
        Adapter.cancel(handle)
        Process.demonitor(handle.ref, [:flush])
      end
    else
      {:error, error} -> emit(owner, token, failed(error))
    end
  end

  defp forward(owner, owner_ref, token, handle, state, deadline, remaining) do
    if now() >= deadline do
      emit(owner, token, failed(Error.new(:timeout, "Provider attempt timed out")))
    else
      receive_provider(owner, owner_ref, token, handle, state, deadline, remaining)
    end
  end

  defp receive_provider(owner, owner_ref, token, handle, state, deadline, remaining) do
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _} ->
        :ok

      {:provider_chunk, event} ->
        remaining = remaining - :erlang.external_size(event)

        if remaining < 0 do
          emit(
            owner,
            token,
            failed(Error.new(:budget_exceeded, "Provider stream output limit exceeded"))
          )
        else
          case ProviderEvents.push(state, event) do
            {:ok, events, state} ->
              Enum.each(events, &emit(owner, token, &1))
              forward(owner, owner_ref, token, handle, state, deadline, remaining)

            {:error, error} ->
              emit(owner, token, failed(error))
          end
        end

      :provider_done ->
        case ProviderEvents.finish(state) do
          {:ok, event} -> emit(owner, token, event)
          {:error, error} -> emit(owner, token, failed(error))
        end

      {:provider_error, error} ->
        emit(owner, token, failed(error))

      {ref, _result} when ref == handle.ref ->
        forward(owner, owner_ref, token, handle, state, deadline, remaining)

      {:DOWN, ref, :process, _, _reason} when ref == handle.ref ->
        emit(
          owner,
          token,
          failed(Error.new(:execution_failure, "Provider ended without terminal event"))
        )
    after
      max(deadline - now(), 0) ->
        emit(owner, token, failed(Error.new(:timeout, "Provider attempt timed out")))
    end
  end

  defp emit(owner, token, event), do: send(owner, {__MODULE__, token, event})
  defp failed(error), do: %{type: :response_failed, error: error}
  defp now, do: System.monotonic_time(:millisecond)

  defp flush(token) do
    receive do
      {__MODULE__, ^token, _} -> flush(token)
    after
      0 -> :ok
    end
  end
end
