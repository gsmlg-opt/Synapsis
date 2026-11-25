defmodule Synapsis.Provider.Realtime.ConnectionTest do
  use ExUnit.Case, async: true

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event.Close
  alias Synapsis.Provider.Realtime.Connection

  test "a policy rejection is distinct from a lost Realtime connection" do
    socket = %WebSocket{}

    assert Connection.receive_event({WebSocket, socket, %Close{code: 1008}}, socket) ==
             {:error, :realtime_policy_rejected}

    assert Connection.receive_event({WebSocket, socket, %Close{code: 1006}}, socket) ==
             {:error, :realtime_disconnected}
  end
end
