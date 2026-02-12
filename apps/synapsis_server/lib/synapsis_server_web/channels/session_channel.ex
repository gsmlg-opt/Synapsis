defmodule SynapsisServerWeb.SessionChannel do
  @moduledoc "WebSocket channel for real-time session interaction."
  use Phoenix.Channel

  @impl true
  def join("session:" <> session_id, _payload, socket) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
    socket = assign(socket, :session_id, session_id)
    {:ok, socket}
  end

  @impl true
  def handle_in("session:message", %{"content" => content}, socket) do
    case Synapsis.Sessions.send_message(socket.assigns.session_id, content) do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("session:cancel", _payload, socket) do
    Synapsis.Sessions.cancel(socket.assigns.session_id)
    {:reply, :ok, socket}
  end

  def handle_in("session:retry", _payload, socket) do
    case Synapsis.Sessions.retry(socket.assigns.session_id) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("session:tool_approve", %{"tool_use_id" => tool_use_id}, socket) do
    Synapsis.Sessions.approve_tool(socket.assigns.session_id, tool_use_id)
    {:reply, :ok, socket}
  end

  def handle_in("session:tool_deny", %{"tool_use_id" => tool_use_id}, socket) do
    Synapsis.Sessions.deny_tool(socket.assigns.session_id, tool_use_id)
    {:reply, :ok, socket}
  end

  def handle_in("session:switch_agent", %{"agent" => agent}, socket) do
    # TODO: Implement agent switching
    {:reply, {:ok, %{agent: agent}}, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({event, payload}, socket) when is_binary(event) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
