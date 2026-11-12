defmodule SynapsisSamgita.AppServer.Plug do
  @moduledoc """
  Endpoint plug for the samgita_protocol host at `/app-server`.

  Requests to any other path pass through untouched. Samgita authenticates with
  the app-server token from `Synapsis.SamgitaConfig`; with no token configured,
  every upgrade is rejected.
  """
  @behaviour Plug

  alias Synapsis.SamgitaConfig
  alias SynapsisSamgita.AppServer.Handler

  @path "/app-server"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: @path} = conn, _opts) do
    SamgitaProtocolWebSocket.Plug.call(conn,
      handler: Handler,
      handler_state: nil,
      authenticate: &__MODULE__.authenticate/1
    )
  end

  def call(conn, _opts), do: conn

  @doc false
  def authenticate(token) when is_binary(token) do
    with {:ok, expected} <- SamgitaConfig.resolve_secret(:app_server_token),
         true <- Plug.Crypto.secure_compare(token, expected) do
      {:ok, :samgita}
    else
      _ -> :error
    end
  end
end
