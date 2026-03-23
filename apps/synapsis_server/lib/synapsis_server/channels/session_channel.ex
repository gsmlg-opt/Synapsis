defmodule SynapsisServer.SessionChannel do
  @moduledoc "WebSocket channel for real-time session interaction."
  use Phoenix.Channel

  require Logger

  @impl true
  def join("session:" <> session_id, _payload, socket) do
    # NOTE: Do NOT call Phoenix.PubSub.subscribe here — the endpoint's
    # pubsub_server is Synapsis.PubSub, so Phoenix automatically subscribes
    # this channel process to the topic on join. A manual subscribe would
    # create a duplicate subscription, causing every broadcast to be
    # delivered (and pushed) twice.
    Synapsis.Sessions.ensure_running(session_id)
    socket = assign(socket, :session_id, session_id)

    messages =
      session_id
      |> Synapsis.Sessions.get_messages()
      |> Enum.map(&serialize_message/1)

    # Load debug state from session
    {debug_enabled, debug_entries} = load_debug_state(session_id)
    socket = assign(socket, :debug, debug_enabled)

    reply = %{
      messages: messages,
      debug: debug_enabled,
      debug_entries: debug_entries
    }

    {:ok, reply, socket}
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
  catch
    :exit, _ ->
      Logger.warning("session_channel_error",
        event: "session:retry",
        reason: "worker_unavailable"
      )

      {:reply, {:error, %{reason: "worker_unavailable"}}, socket}
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

  def handle_in("toggle_debug", %{"enabled" => enabled}, socket) do
    session_id = socket.assigns.session_id

    case Synapsis.Sessions.update_debug(session_id, enabled) do
      {:ok, _session} ->
        broadcast!(socket, "debug_toggled", %{enabled: enabled})
        {:noreply, assign(socket, :debug, enabled)}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "Failed to toggle debug"}}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({event, payload}, socket) when is_binary(event) do
    # Filter debug events based on debug flag
    case event do
      "debug_request" ->
        if socket.assigns[:debug], do: push(socket, event, payload)

      "debug_response" ->
        if socket.assigns[:debug], do: push(socket, event, payload)

      _ ->
        push(socket, event, payload)
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Debug state loading --

  defp load_debug_state(session_id) do
    case Synapsis.Repo.get(Synapsis.Session, session_id) do
      %{debug: true} ->
        entries =
          if Code.ensure_loaded?(SynapsisServer.DebugStore) and
               Process.whereis(SynapsisServer.DebugStore) != nil do
            SynapsisServer.DebugStore.list_entries(session_id)
          else
            []
          end

        {true, entries}

      _ ->
        {false, []}
    end
  end

  # -- Serialization --

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
