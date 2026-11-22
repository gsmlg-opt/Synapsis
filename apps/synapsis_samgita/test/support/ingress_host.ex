defmodule SynapsisSamgita.Test.IngressHost do
  @moduledoc false
  def init(opts), do: opts

  def call(conn, opts) do
    if conn.request_path == "/app-server" do
      conn |> WebSockAdapter.upgrade(__MODULE__.Socket, opts, timeout: 60_000) |> Plug.Conn.halt()
    else
      Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock
    alias SamgitaProtocolWebSocket.Socket, as: Native
    def init(opts), do: {:ok, %{test: opts[:test], native: nil}}

    def handle_in({text, opcode: :text}, %{native: nil} = state) do
      bootstrap = JSON.decode!(text)
      send(state.test, {:bootstrap, self(), bootstrap})

      {:push, {:text, JSON.encode!(%{"type" => "agent/pending", "request_id" => "request-1"})},
       state}
    end

    def handle_in(_frame, %{silent: true} = state), do: {:ok, state}
    def handle_in(frame, state), do: Native.handle_in(frame, state.native) |> result(state)

    def handle_info(:silence_native, state), do: {:ok, Map.put(state, :silent, true)}

    def handle_info({:approve, connection}, state),
      do: handle_info({:approve, connection, connection["id"]}, state)

    def handle_info({:approve, connection, native_id}, state) do
      {:ok, native} =
        Native.init(
          principal: :fixture,
          handler: SynapsisSamgita.Test.IngressHost.Handler,
          handler_state: %{test: state.test},
          connection_id: native_id
        )

      {:push, {:text, JSON.encode!(%{"type" => "agent/connected", "connection" => connection})},
       %{state | native: native}}
    end

    def handle_info({:request, method, params, command_id}, state),
      do:
        Native.handle_info(
          {:protocol_request, method, params, [command_id: command_id]},
          state.native
        )
        |> result(state)

    def handle_info({:close, code}, state), do: {:stop, :normal, code, state}
    def handle_info(_message, %{native: nil} = state), do: {:ok, state}

    def handle_info(message, state),
      do: Native.handle_info(message, state.native) |> result(state)

    def terminate(_reason, %{native: nil}), do: :ok
    def terminate(reason, state), do: Native.terminate(reason, state.native)

    defp result({:push, frames, native}, state) do
      if native.server.client.phase == :ready and state.native.server.client.phase != :ready,
        do: send(state.test, {:native_ready, self()})

      {:push, frames, %{state | native: native}}
    end

    defp result({:ok, native}, state), do: {:ok, %{state | native: native}}

    defp result({:stop, reason, code, native}, state),
      do: {:stop, reason, code, %{state | native: native}}
  end

  defmodule Handler do
    @moduledoc false
    @behaviour SamgitaProtocol.Handler
    def capabilities, do: ["project_events.v1"]
    def methods, do: SamgitaProtocol.Capabilities.methods(capabilities())

    def handle_request(_, _, _, state),
      do: {:error, SamgitaProtocol.Error.new("unsupported_method"), state}

    def handle_response(method, result, context, state) do
      send(state.test, {:host_response, self(), method, result, context})
      {:ok, state}
    end
  end
end
