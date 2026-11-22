defmodule SynapsisLocalAgents.Test.SigmaHost do
  @moduledoc """
  A samgita_protocol host standing in for Sigma's `/app-server`: it reports each
  connection socket and request to the test process and answers requests with
  `replies.(method, params)`.
  """
  alias SamgitaProtocol.Capabilities
  alias SamgitaProtocolWebSocket.Server

  @doc "Starts a host on a free loopback port; returns `{listener, url}`."
  def start(token, replies) do
    test = self()

    {:ok, listener} =
      Server.start_link(
        port: 0,
        handler: __MODULE__.Handler,
        authenticate: fn supplied ->
          if supplied == token, do: {:ok, :sigma}, else: :error
        end,
        handler_state: fn _principal ->
          send(test, {:host_socket, self()})
          %{test: test, replies: replies}
        end
      )

    {:ok, {_address, port}} = Server.listener_info(listener)
    {listener, "ws://127.0.0.1:#{port}/app-server"}
  end

  def notification(method, params, stream \\ nil) do
    base = %{
      "schema_version" => "1.0",
      "type" => "notification",
      "correlation_id" => "n-#{System.unique_integer([:positive])}",
      "method" => method,
      "params" => params
    }

    case stream do
      {stream_id, cursor} -> Map.merge(base, %{"stream_id" => stream_id, "cursor" => cursor})
      nil -> base
    end
  end

  defmodule Handler do
    @moduledoc false
    @behaviour SamgitaProtocol.Handler

    @impl true
    def capabilities, do: ["sessions.v1", "streaming.v1", "cancellation.v1"]

    @impl true
    def methods, do: Capabilities.methods(capabilities())

    @impl true
    def handle_request(method, params, context, state) do
      send(state.test, {:host_request, method, params, context, self()})

      case state.replies.(method, params) do
        {:ok, result} -> {:ok, result, state}
        {:error, error} -> {:error, error, state}
      end
    end
  end
end
