defmodule SynapsisServer.AgentDaemonChannel do
  @moduledoc "Read-only channel for daemon and Backplane lifecycle events."

  use Phoenix.Channel

  alias Synapsis.Agent.Daemon
  alias SynapsisServer.AgentDaemonEvent

  @impl true
  def join("agent:daemon", _payload, socket) do
    # The endpoint automatically subscribes the channel process to its topic.
    {:ok, %{status: Daemon.status()}, socket}
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "read_only"}}, socket}
  end

  @impl true
  def handle_info(message, socket) do
    case AgentDaemonEvent.map(message) do
      {:ok, {event, payload}} -> push(socket, event, payload)
      :ignore -> :ok
    end

    {:noreply, socket}
  end
end
