defmodule Synapsis.Provider.Transport.HTTP do
  @moduledoc false

  @max_body 16 * 1024 * 1024

  def request(url, opts) do
    {max_bytes, opts} = Keyword.pop(opts, :max_bytes, @max_body)

    opts = Keyword.put(opts, :max_decoded_body_size, max_bytes)

    result =
      with_response(url, opts, fn response, deadline ->
        with {:ok, {_size, chunks}} <-
               reduce_body(response, {0, []}, deadline, fn data, {size, chunks} ->
                 if size + byte_size(data) <= max_bytes,
                   do: {:cont, {size + byte_size(data), [data | chunks]}},
                   else: {:error, :response_too_large}
               end) do
          {:ok, %{response | body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}
        end
      end)

    case result do
      {:error, %HTTP.RequestError{reason: :decoded_body_too_large}} ->
        {:error, :response_too_large}

      result ->
        result
    end
  end

  def json(url, opts) do
    with {:ok, response} <- request(url, opts) do
      content_type = HTTP.Headers.get(response.headers, "content-type") || ""

      if String.contains?(content_type, ["/json", "+json"]) and response.body != "" do
        with {:ok, body} <- Formata.JSON.decode(response.body),
             do: {:ok, %{response | body: body}}
      else
        {:ok, response}
      end
    end
  end

  def with_response(url, opts, fun) do
    timeout = Keyword.fetch!(opts, :timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    {watcher, watcher_ref, signal} = abort_watcher()

    try do
      promise =
        HTTP.fetch(
          url,
          Keyword.merge(opts,
            stream_response: true,
            redirect: :manual,
            retry: false,
            http2_unprocessed_retry: false,
            connect_timeout: min(timeout, 30_000),
            response_stream_idle_timeout: timeout,
            response_stream_ack_timeout: timeout,
            error_mode: :structured,
            signal: signal
          )
        )

      try do
        case HTTP.Promise.await(promise, :infinity) do
          %HTTP.Response{} = response -> fun.(response, deadline)
          {:error, _reason} = error -> error
        end
      after
        HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise), 1_000)
      end
    after
      send(watcher, {watcher_ref, :done})
    end
  end

  # The fetch promise is unlinked. Keep cancellation effective before the response
  # reader is registered as well as while it consumes the body.
  defp abort_watcher do
    caller = self()
    ref = make_ref()

    {:ok, watcher} =
      Task.Supervisor.start_child(Synapsis.Provider.TaskSupervisor, fn ->
        monitor = Process.monitor(caller)
        signal = HTTP.AbortController.new()
        send(caller, {ref, signal})

        receive do
          {^ref, :done} -> :ok
          {:DOWN, ^monitor, :process, ^caller, _reason} -> HTTP.AbortController.abort(signal)
        end

        Agent.stop(signal)
        Process.demonitor(monitor, [:flush])
      end)

    receive do
      {^ref, signal} -> {watcher, ref, signal}
    after
      1_000 ->
        send(watcher, {ref, :done})
        raise "HTTP cancellation monitor did not start"
    end
  end

  def reduce_body(%HTTP.Response{body: stream}, acc, deadline, fun) when is_pid(stream) do
    monitor = Process.monitor(stream)
    send(stream, {:read_chunk, self(), :ack})

    try do
      read_chunks(stream, monitor, acc, deadline, fun)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def reduce_body(%HTTP.Response{body: body}, acc, _deadline, fun) do
    case fun.(body || "", acc) do
      {:cont, acc} -> {:ok, acc}
      {:halt, acc} -> {:ok, acc}
      {:error, _reason} = error -> error
    end
  end

  defp read_chunks(stream, monitor, acc, deadline, fun) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, %HTTP.RequestError{reason: :timeout}}
    else
      receive do
        {:stream_chunk, ^stream, data, ack_ref} ->
          case fun.(data, acc) do
            {:cont, acc} ->
              send(stream, {:stream_chunk_ack, ack_ref})
              read_chunks(stream, monitor, acc, deadline, fun)

            {:halt, acc} ->
              {:ok, acc}

            {:error, _reason} = error ->
              error
          end

        {:stream_end, ^stream} ->
          {:ok, acc}

        {:stream_trailers, ^stream, _headers} ->
          read_chunks(stream, monitor, acc, deadline, fun)

        {:stream_error, ^stream, reason} ->
          {:error, %HTTP.RequestError{reason: reason}}

        {:DOWN, ^monitor, :process, ^stream, reason} ->
          {:error, %HTTP.RequestError{reason: {:stream_down, reason}}}
      after
        remaining ->
          {:error, %HTTP.RequestError{reason: :timeout}}
      end
    end
  end
end
