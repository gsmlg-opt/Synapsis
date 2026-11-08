defmodule Synapsis.Provider.Speech.FishAudio.Stream do
  @moduledoc """
  A single-consumer Fish HTTP stream, owned by one supervised linked task.

  Opening waits for response headers; each read demands the next transport chunk.
  Normal EOF returns Finch's connection through its normal completion path, while
  the small logical owner remains until explicit release. Release drains the task
  and monitor and is idempotent. Handles and monotonic deadlines must never be
  serialized or persisted. HTTP/2 transport backpressure is not promised.
  """

  defstruct [:task, :token, :deadline_ms]

  @doc false
  def open(built) do
    caller = self()
    token = make_ref()

    task =
      Task.Supervisor.async(Synapsis.Provider.TaskSupervisor, fn ->
        owner(caller, token, built)
      end)

    handle = %__MODULE__{task: task, token: token, deadline_ms: built.deadline_ms}

    receive do
      {:fish_stream, ^token, :ready} ->
        {:ok, handle}

      {:fish_stream, ^token, {:error, reason}} ->
        shutdown(handle)
        {:error, reason}

      {ref, _} when ref == task.ref ->
        shutdown(handle)
        {:error, :transport}

      {:DOWN, ref, :process, _pid, _reason} when ref == task.ref ->
        shutdown(handle)
        {:error, :transport}
    after
      remaining(handle) ->
        shutdown(handle)
        {:error, :timeout}
    end
  end

  @spec read(t()) :: {:ok, binary()} | :eof | {:error, term()}
  def read(%__MODULE__{task: task, token: token} = handle) do
    request = make_ref()
    send(task.pid, {:fish_read, token, self(), request})

    receive do
      {:fish_reply, ^request, result} ->
        result

      {ref, _} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:error, :closed}

      {:DOWN, ref, :process, _pid, _reason} when ref == task.ref ->
        {:error, :closed}
    after
      remaining(handle) ->
        shutdown(handle)
        {:error, :timeout}
    end
  end

  @spec release(t()) :: :ok
  def release(%__MODULE__{task: task, token: token} = handle) do
    if Process.alive?(task.pid) do
      request = make_ref()
      send(task.pid, {:fish_release, token, self(), request})

      receive do
        {:fish_reply, ^request, :released} ->
          case Task.yield(task, remaining(handle)) do
            nil -> shutdown(handle)
            _ -> :ok
          end

        {ref, _} when ref == task.ref ->
          Process.demonitor(task.ref, [:flush])

        {:DOWN, ref, :process, _pid, _reason} when ref == task.ref ->
          :ok
      after
        remaining(handle) -> shutdown(handle)
      end
    else
      drain(task)
    end

    :ok
  end

  @type t :: %__MODULE__{task: Task.t(), token: reference(), deadline_ms: integer()}

  defp owner(caller, token, built) do
    state = %{
      caller: caller,
      token: token,
      deadline_ms: built.deadline_ms,
      status: nil,
      ready: false,
      size: 0,
      max_bytes: built.max_bytes,
      error: nil,
      release: nil
    }

    duration = remaining(state)
    request = Finch.build(:post, built.url, built.headers, Jason.encode!(built.body))

    result =
      Finch.stream_while(request, Req.Finch, state, &event/2,
        pool_timeout: duration,
        receive_timeout: duration,
        request_timeout: duration
      )

    case result do
      {:ok, state} -> finish(state)
      {:error, _reason, state} -> finish(%{state | error: state.error || :transport})
    end
  rescue
    _ -> send(caller, {:fish_stream, token, {:error, :transport}})
  catch
    :exit, _ -> send(caller, {:fish_stream, token, {:error, :transport}})
  end

  defp event({:status, status}, state), do: {:cont, %{state | status: status}}

  defp event({:headers, headers}, state) do
    type =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(key) == "content-type", do: String.downcase(value)
      end)

    cond do
      state.status not in 200..299 ->
        {:halt, %{state | error: {:http_status, state.status}}}

      not audio_type?(type) ->
        {:halt, %{state | error: :invalid_audio}}

      remaining(state) == 0 ->
        {:halt, %{state | error: :timeout}}

      true ->
        send(state.caller, {:fish_stream, state.token, :ready})
        {:cont, %{state | ready: true}}
    end
  end

  defp event({:data, ""}, state), do: {:cont, state}

  defp event({:data, bytes}, state) do
    if state.size + byte_size(bytes) > state.max_bytes do
      {:halt, %{state | error: :response_too_large}}
    else
      token = state.token

      receive do
        {:fish_read, ^token, caller, request} ->
          if remaining(state) > 0 do
            send(caller, {:fish_reply, request, {:ok, bytes}})
            {:cont, %{state | size: state.size + byte_size(bytes)}}
          else
            send(caller, {:fish_reply, request, {:error, :timeout}})
            {:halt, %{state | error: :timeout}}
          end

        {:fish_release, ^token, caller, request} ->
          {:halt, %{state | release: {caller, request}}}
      after
        remaining(state) -> {:halt, %{state | error: :timeout}}
      end
    end
  end

  defp event({:trailers, _headers}, state), do: {:cont, state}

  # Finch has finished before this loop. EOF therefore releases the transport,
  # while explicit release ends this logical owner and its Task monitor.
  defp finish(%{release: {caller, request}}) do
    send(caller, {:fish_reply, request, :released})
    :ok
  end

  defp finish(%{ready: false} = state) do
    send(state.caller, {:fish_stream, state.token, {:error, state.error || :transport}})
    :ok
  end

  defp finish(state) do
    token = state.token

    receive do
      {:fish_read, ^token, caller, request} ->
        result = if state.error, do: {:error, state.error}, else: :eof
        send(caller, {:fish_reply, request, result})
        finish(state)

      {:fish_release, ^token, caller, request} ->
        send(caller, {:fish_reply, request, :released})
        :ok
    after
      remaining(state) -> :ok
    end
  end

  defp remaining(%{deadline_ms: deadline}),
    do: max(0, deadline - System.monotonic_time(:millisecond))

  defp audio_type?(nil), do: true

  defp audio_type?(type) do
    type = type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    String.starts_with?(type, "audio/") or
      type in ["application/octet-stream", "binary/octet-stream", "application/ogg"]
  end

  defp shutdown(%{task: task}) do
    Task.shutdown(task, :brutal_kill)
    drain(task)
  end

  defp drain(task) do
    Process.demonitor(task.ref, [:flush])

    receive do
      {ref, _} when ref == task.ref -> :ok
    after
      0 -> :ok
    end
  end
end
