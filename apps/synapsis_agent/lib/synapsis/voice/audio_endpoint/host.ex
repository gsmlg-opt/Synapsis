defmodule Synapsis.Voice.AudioEndpoint.Host do
  @moduledoc """
  Linux device endpoint backed by PulseAudio or PipeWire-Pulse.

  The supervised Port owns the device streams and a WebRTC echo-cancel module.
  Playback positions subtract PulseAudio's measured queued latency. Opening an
  endpoint requires an explicit owner. Its death closes the helper and devices.
  """
  use GenServer

  @operation_timeout 5_000
  @maximum_audio_bytes 96_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def devices, do: probe()
  def status(pid), do: GenServer.call(pid, :status, @operation_timeout)
  def cursor(pid), do: GenServer.call(pid, {:command, "cursor", %{}}, @operation_timeout)

  def stop_playback(pid),
    do: GenServer.call(pid, {:command, "stop_playback", %{}}, @operation_timeout)

  def mute(pid, muted) when is_boolean(muted),
    do: GenServer.call(pid, {:command, "mute", %{muted: muted}}, @operation_timeout)

  def close(pid), do: GenServer.stop(pid, :normal, @operation_timeout)

  def play(pid, pcm, metadata) do
    with :ok <- validate_audio(pcm, metadata) do
      GenServer.call(pid, {:play, pcm, metadata}, @operation_timeout)
    end
  end

  def validate_audio(pcm, %{response_id: response, item_id: item, content_index: index})
      when is_binary(pcm) and byte_size(pcm) > 0 and byte_size(pcm) <= @maximum_audio_bytes and
             rem(byte_size(pcm), 2) == 0 and is_binary(response) and response != "" and
             is_binary(item) and item != "" and is_integer(index) and index >= 0,
      do: :ok

  def validate_audio(_, _), do: {:error, :invalid_audio}

  @impl true
  def init(options) do
    owner = Keyword.fetch!(options, :owner)

    case :global.register_name({__MODULE__, node()}, self()) do
      :yes ->
        {:ok,
         %{
           owner: owner,
           owner_ref: Process.monitor(owner),
           generation: Keyword.fetch!(options, :generation),
           options: options,
           port: nil,
           info: nil,
           pending: %{},
           next_id: 1
         }, {:continue, :open}}

      :no ->
        {:stop, :host_audio_busy}
    end
  end

  @impl true
  def handle_continue(:open, state) do
    with {:ok, port} <- open_helper() do
      command = %{
        command: "start",
        input_device: Keyword.get(state.options, :input_device),
        output_device: Keyword.get(state.options, :output_device)
      }

      if write(port, command) do
        Process.send_after(self(), :open_timeout, 8_000)
        {:noreply, %{state | port: port}}
      else
        Port.close(port)
        {:stop, :helper_unavailable, state}
      end
    else
      {:error, reason} ->
        notify(state, {:error, reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, %{status: if(state.info, do: :ready, else: :connecting), info: state.info}},
     state}
  end

  def handle_call({:play, pcm, metadata}, _from, %{info: info} = state) when not is_nil(info) do
    if write(state.port, %{command: "play", pcm: Base.encode64(pcm), metadata: metadata}) do
      {:reply, :ok, state}
    else
      {:stop, :normal, {:error, :helper_backpressure}, state}
    end
  end

  def handle_call({:command, command, arguments}, from, %{info: info} = state)
      when not is_nil(info) do
    id = state.next_id

    if map_size(state.pending) < 16 and
         write(state.port, Map.merge(arguments, %{command: command, id: id})) do
      timer = Process.send_after(self(), {:command_timeout, id}, 4_000)
      pending = Map.put(state.pending, id, {from, timer})
      {:noreply, %{state | pending: pending, next_id: id + 1}}
    else
      {:reply, {:error, :helper_backpressure}, state}
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :endpoint_not_ready}, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Formata.JSON.decode(data) do
      {:ok, %{"event" => "ready", "info" => info}} ->
        notify(state, {:ready, info})
        {:noreply, %{state | info: info}}

      {:ok, %{"event" => "capture", "pcm" => encoded}} ->
        case Base.decode64(encoded) do
          {:ok, pcm} when byte_size(pcm) <= 1_920 ->
            if capture_consumer_ready?(state.owner) do
              notify(state, {:capture, pcm})
              {:noreply, state}
            else
              notify(state, {:error, :capture_consumer_overflow})
              {:stop, :normal, state}
            end

          _ ->
            notify(state, {:error, :invalid_capture})
            {:stop, :normal, state}
        end

      {:ok, %{"event" => "cursor", "cursor" => cursor}} ->
        notify(state, {:cursor, cursor})
        {:noreply, state}

      {:ok, %{"reply" => id, "result" => result}} ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            {:noreply, state}

          {{from, timer}, pending} ->
            Process.cancel_timer(timer)
            GenServer.reply(from, {:ok, result})
            {:noreply, %{state | pending: pending}}
        end

      {:ok, %{"event" => "error", "reason" => reason}} ->
        notify(state, {:error, reason})
        {:stop, :normal, state}

      _ ->
        notify(state, {:error, :invalid_helper_event})
        {:stop, :normal, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    notify(state, {:error, {:helper_exit, status}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:open_timeout, %{info: nil} = state) do
    notify(state, {:error, :device_open_timeout})
    {:stop, :normal, state}
  end

  def handle_info({:command_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _}, pending} ->
        GenServer.reply(from, {:error, :audio_operation_timeout})
        notify(state, {:error, :audio_operation_timeout})
        {:stop, :normal, %{state | pending: pending}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.port && Port.info(state.port) do
      write(state.port, %{command: "close"})
      Port.close(state.port)
    end

    Enum.each(state.pending, fn {_, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :endpoint_closed})
    end)

    :global.unregister_name({__MODULE__, node()})
    :ok
  end

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  defp capture_consumer_ready?(owner) do
    case Process.info(owner, :message_queue_len) do
      {:message_queue_len, count} -> count < 200
      nil -> false
    end
  end

  defp notify(state, event),
    do: send(state.owner, {:audio_endpoint, state.generation, event})

  defp probe do
    with {:ok, port} <- open_helper() do
      try do
        write(port, %{command: "devices", id: 1})

        receive do
          {^port, {:data, data}} ->
            case Formata.JSON.decode(data) do
              {:ok, %{"result" => result}} -> {:ok, result}
              {:ok, %{"reason" => reason}} -> {:error, reason}
              _ -> {:error, :invalid_helper_event}
            end

          {^port, {:exit_status, status}} ->
            {:error, {:helper_exit, status}}
        after
          @operation_timeout -> {:error, :audio_probe_timeout}
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  end

  defp open_helper do
    cond do
      :os.type() != {:unix, :linux} ->
        {:error, :host_audio_platform_unsupported}

      is_nil(System.find_executable("pactl")) ->
        {:error, :pactl_missing}

      is_nil(System.find_executable("python3")) ->
        {:error, :python3_missing}

      true ->
        helper = Application.app_dir(:synapsis_agent, "priv/voice/pulse_audio.py")
        executable = System.find_executable("python3")

        {:ok,
         Port.open({:spawn_executable, executable}, [
           :binary,
           {:packet, 4},
           :exit_status,
           {:args, [helper]}
         ])}
    end
  rescue
    _ -> {:error, :audio_helper_start_failed}
  end

  defp write(port, command) do
    Port.command(port, Formata.JSON.encode!(command), [:nosuspend])
  rescue
    ArgumentError -> false
  end
end
