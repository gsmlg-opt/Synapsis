defmodule SynapsisServer.SessionChannel do
  @moduledoc "WebSocket channel for real-time session interaction."
  use Phoenix.Channel

  require Logger

  @impl true
  def join("session:" <> session_id, _payload, socket) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
    Synapsis.Sessions.ensure_running(session_id)
    socket = assign(socket, :session_id, session_id)

    messages =
      session_id
      |> Synapsis.Sessions.get_messages()
      |> Enum.map(&serialize_message/1)

    {:ok, %{messages: messages}, socket}
  end

  @impl true
  def handle_in("session:message", %{"content" => content, "images" => images}, socket)
      when is_list(images) do
    case Synapsis.Sessions.send_message(socket.assigns.session_id, %{
           content: content,
           images: images
         }) do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("session_channel_error", event: "session:message", reason: inspect(reason))
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end

  def handle_in("session:message", %{"content" => content}, socket) do
    case Synapsis.Sessions.send_message(socket.assigns.session_id, content) do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("session_channel_error", event: "session:message", reason: inspect(reason))
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end

  def handle_in("session:cancel", _payload, socket) do
    Synapsis.Sessions.cancel(socket.assigns.session_id)
    {:reply, :ok, socket}
  end

  def handle_in("session:retry", _payload, socket) do
    case Synapsis.Sessions.retry(socket.assigns.session_id) do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("session_channel_error", event: "session:retry", reason: inspect(reason))
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
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
    case Synapsis.Sessions.switch_agent(socket.assigns.session_id, agent) do
      :ok ->
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("session_channel_error",
          event: "session:switch_agent",
          reason: inspect(reason)
        )

        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
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

  defp serialize_message(message) do
    %{
      id: message.id,
      role: message.role,
      parts: Enum.map(message.parts, &serialize_part/1),
      inserted_at: message.inserted_at
    }
  end

  defp serialize_part(%Synapsis.Part.Text{content: content}),
    do: %{type: "text", content: content}

  defp serialize_part(%Synapsis.Part.ToolUse{} = p),
    do: %{
      type: "tool_use",
      tool: p.tool,
      tool_use_id: p.tool_use_id,
      input: p.input,
      status: p.status
    }

  defp serialize_part(%Synapsis.Part.ToolResult{} = p),
    do: %{
      type: "tool_result",
      tool_use_id: p.tool_use_id,
      content: p.content,
      is_error: p.is_error
    }

  defp serialize_part(%Synapsis.Part.Reasoning{content: content}),
    do: %{type: "reasoning", content: content}

  defp serialize_part(%Synapsis.Part.File{path: path, content: content}),
    do: %{type: "file", path: path, content: content}

  defp serialize_part(%Synapsis.Part.Image{media_type: mt, data: data}),
    do: %{type: "image", media_type: mt, data: data}

  defp serialize_part(%Synapsis.Part.Agent{agent: agent, message: message}),
    do: %{type: "agent", agent: agent, message: message}

  defp serialize_part(_), do: %{type: "unknown"}

  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(_reason), do: "Operation failed"
end
