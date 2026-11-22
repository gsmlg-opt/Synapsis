defmodule SynapsisSamgita.Inbound.Client do
  @moduledoc "A remembered device bootstrap followed by validated native bidirectional protocol messages."
  use GenServer, restart: :transient

  alias HTTP.WebSocket, as: Socket
  alias HTTP.WebSocket.Event.{Open, Frame, Close, Error}
  alias SamgitaProtocol.{Client, Codec}
  alias Synapsis.Samgita.Devices
  alias SynapsisSamgita.{Events, AppServer.Handler}

  @keepalive 15_000
  @timeout 5_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :device_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {SynapsisSamgita.DeviceRegistry, id}}
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :device_id)

    state = %{
      id: id,
      handler: Keyword.get(opts, :handler, Handler),
      socket: nil,
      monitor: nil,
      core: nil,
      task: nil,
      timer: nil,
      keepalive: nil,
      retry: 1_000,
      reconnect_token: nil,
      device: nil,
      token: nil,
      status: %{
        device_id: id,
        state: :connecting,
        agent_id: nil,
        connection_id: nil,
        generation: nil,
        last_error: nil
      }
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: open(state)

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({:reconnect, token}, %{reconnect_token: token} = state),
    do: open(%{state | timer: nil, reconnect_token: nil})

  def handle_info({Socket, socket, %Open{}}, %{socket: socket} = state) do
    attrs = %{
      "type" => "agent/connect",
      "name" => state.device["name"],
      "implementation" => state.device["implementation"],
      "device_token" => state.token
    }

    case Socket.send(socket, JSON.encode!(attrs)) do
      :ok ->
        {:noreply,
         publish(
           %{state | keepalive: Process.send_after(self(), {:keepalive, socket.ref}, @keepalive)},
           :connecting
         )}

      _ ->
        {:noreply, lost(state, "connect_failed")}
    end
  end

  def handle_info(
        {Socket, socket, %Frame{opcode: :text, data: text}, ref},
        %{socket: socket} = state
      ) do
    next = receive_text(text, state)
    Socket.acknowledge(socket, ref)
    {:noreply, next}
  end

  def handle_info({Socket, socket, %Frame{}, ref}, %{socket: socket} = state) do
    Socket.acknowledge(socket, ref)
    {:noreply, state}
  end

  # TODO(upstream): gsmlg-opt/Samgita#6 - temporary closes and permanent rejection share 1008.
  def handle_info({Socket, socket, %Close{code: 1008}}, %{socket: socket} = state) do
    Devices.disable(state.id)
    {:noreply, state |> close() |> publish(:error, "policy_closed")}
  end

  def handle_info({Socket, socket, event}, %{socket: socket} = state)
      when is_struct(event, Close) or is_struct(event, Error),
      do: {:noreply, lost(state, "disconnected")}

  def handle_info({:keepalive, ref}, %{socket: %Socket{ref: ref}} = state) do
    case Socket.send_frame(state.socket, {:ping, ""}) do
      :ok ->
        {:noreply,
         %{
           state
           | keepalive: Process.send_after(self(), {:keepalive, state.socket.ref}, @keepalive)
         }}

      _ ->
        {:noreply, lost(state, "disconnected")}
    end
  end

  def handle_info(
        {:initialize_expired, ref},
        %{socket: %Socket{ref: ref}, status: %{state: phase}} = state
      )
      when phase in [:connecting, :initializing],
      do: {:noreply, lost(state, "initialize_timeout")}

  def handle_info({ref, result}, %{task: %{ref: ref, request: request}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case Client.reply(state.core, request, result) do
      {:ok, message, core} ->
        case send_message(state.socket, message) do
          :ok -> {:noreply, %{state | core: core}}
          _ -> {:noreply, lost(state, "response_lost")}
        end

      _ ->
        {:noreply, lost(state, "invalid_response")}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state),
    do: {:noreply, lost(%{state | task: nil}, "handler_failed")}

  def handle_info({:handler_expired, ref}, %{task: %{ref: ref}} = state),
    do: {:noreply, lost(state, "handler_timeout")}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:noreply, lost(state, "disconnected")}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state)
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  defp open(state) do
    with {:ok, %{"enabled" => true, "forgotten" => false} = device} <- Devices.get(state.id),
         {:ok, token} <- Devices.resolve_token(state.id),
         %Socket{} = socket <-
           Socket.new(socket_url(device["base_url"]), [],
             mode: :proxy,
             http_version: :http1,
             delivery: :ack,
             opening_timeout: @timeout,
             write_timeout: @timeout,
             close_timeout: 1_000,
             idle_timeout: 45_000,
             max_message_size: 262_144,
             max_frame_bytes: 262_144,
             max_queue_bytes: 524_288,
             max_queue_events: 8
           ) do
      timer = Process.send_after(self(), {:initialize_expired, socket.ref}, @timeout)

      {:noreply,
       publish(
         %{
           state
           | socket: socket,
             monitor: Process.monitor(socket.pid),
             device: device,
             token: token,
             timer: timer
         },
         :connecting
       )}
    else
      {:ok, _} ->
        {:stop, :normal, state}

      {:error, :credential_unavailable} ->
        {:noreply, publish(state, :error, "credential_unavailable")}

      _ ->
        {:noreply, lost(state, "connect_failed")}
    end
  end

  defp socket_url(url) do
    uri = URI.parse(url)

    URI.to_string(%{
      uri
      | scheme: if(uri.scheme == "https", do: "wss", else: "ws"),
        path: "/app-server"
    })
  end

  defp receive_text(text, %{core: nil} = state) do
    case JSON.decode(text) do
      {:ok, %{"type" => "agent/pending", "request_id" => request_id}}
      when is_binary(request_id) ->
        cancel(state.timer)
        publish(%{state | timer: nil}, :pending)

      {:ok, %{"type" => "agent/connected", "connection" => connection}} ->
        initialize(connection, state)

      _ ->
        lost(state, "invalid_bootstrap")
    end
  end

  defp receive_text(text, state) do
    case Client.receive(state.core, text) do
      {:ok, effects, core} -> Enum.reduce(effects, %{state | core: core}, &effect/2)
      _ -> lost(state, "invalid_message")
    end
  end

  defp initialize(connection, state) do
    with {:ok, device} <- Devices.record_connection(state.id, connection),
         {:ok, core} <-
           Client.new(
             capabilities: ["project_events.v1"],
             max_pending: 1,
             max_frame_bytes: 262_144,
             request_timeout_ms: @timeout
           ),
         {:ok, message, core} <-
           Client.request(
             core,
             "connection/initialize",
             %{
               "versions" => ["1.0"],
               "capabilities" => ["project_events.v1"],
               "required_capabilities" => ["project_events.v1"]
             },
             id: Ecto.UUID.generate()
           ),
         :ok <- send_message(state.socket, message) do
      cancel(state.timer)

      status = %{
        state.status
        | agent_id: device["agent_id"],
          connection_id: device["connection_id"],
          generation: device["generation"]
      }

      publish(
        %{
          state
          | device: device,
            core: core,
            status: status,
            timer: Process.send_after(self(), {:initialize_expired, state.socket.ref}, @timeout)
        },
        :initializing
      )
    else
      _ -> lost(state, "invalid_connection")
    end
  end

  defp effect(
         {:response, _id, %{"capabilities" => groups, "connection_id" => connection_id}},
         %{status: %{state: :initializing}} = state
       ) do
    if "project_events.v1" in groups and connection_id == state.status.connection_id do
      cancel(state.timer)
      publish(%{state | timer: nil, retry: 1_000}, :connected)
    else
      lost(state, "connection_mismatch")
    end
  end

  defp effect({:request, request}, %{task: nil, status: %{state: :connected}} = state) do
    id = state.id
    handler = state.handler

    task =
      Task.Supervisor.async(SynapsisSamgita.TaskSupervisor, fn ->
        case handler.handle_request(request["method"], request["params"], %{}, %{device_id: id}) do
          {:ok, result, _} -> {:ok, result}
          {:error, error, _} -> {:error, error}
        end
      end)

    Process.send_after(self(), {:handler_expired, task.ref}, 4_500)
    %{state | task: %{pid: task.pid, ref: task.ref, request: request}}
  end

  defp effect(_, state), do: lost(state, "unexpected_message")

  defp send_message(socket, message) do
    with {:ok, text} <- Codec.encode(message, max_frame_bytes: 262_144),
         do: Socket.send(socket, text)
  end

  defp lost(state, reason) do
    state = close(state)
    token = make_ref()
    timer = Process.send_after(self(), {:reconnect, token}, state.retry)

    publish(
      %{state | timer: timer, reconnect_token: token, retry: min(state.retry * 2, 30_000)},
      :offline,
      reason
    )
  end

  defp close(state) do
    cancel(state.timer)
    cancel(state.keepalive)

    if state.task,
      do: Task.Supervisor.terminate_child(SynapsisSamgita.TaskSupervisor, state.task.pid)

    if state.socket, do: Socket.close(state.socket)
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])

    %{
      state
      | socket: nil,
        monitor: nil,
        core: nil,
        task: nil,
        timer: nil,
        reconnect_token: nil,
        keepalive: nil,
        token: nil
    }
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp publish(state, phase, error \\ nil) do
    status = %{state.status | state: phase, last_error: error}
    Events.broadcast_device_status(status)
    %{state | status: status}
  end
end
