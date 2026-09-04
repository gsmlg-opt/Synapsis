defmodule SynapsisServer.UserSocket do
  use Phoenix.Socket

  channel "agent:daemon", SynapsisServer.AgentDaemonChannel
  channel "session:*", SynapsisServer.SessionChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
