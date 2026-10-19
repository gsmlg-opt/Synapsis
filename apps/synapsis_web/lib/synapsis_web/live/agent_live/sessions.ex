defmodule SynapsisWeb.AgentLive.Sessions do
  @moduledoc "Chat interface for a named agent with session sidebar and PubSub streaming."
  use SynapsisWeb, {:live_view, log: false}
  require Logger

  alias Synapsis.{ContextWindow, Image, Providers, Sessions}
  alias Synapsis.Session.{PendingInputStore, Worker}
  alias SynapsisWeb.{ChatBridge, AgentLive.SessionChat}

  @running_statuses ~w(streaming tool_executing)

  @impl true
  def mount(%{"agent_id" => agent_id}, _session, socket) do
    agent_config = Synapsis.Agent.Resolver.resolve(agent_id)
    provider_configured? = not is_nil(agent_config.provider)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "heartbeat:notifications")
    end

    {:ok,
     assign(socket,
       page_title: "#{String.capitalize(agent_id)} Agent",
       agent_id: agent_id,
       agent_config: agent_config,
       configured_models: Providers.configured_models(),
       provider_configured: provider_configured?,
       sessions: [],
       current_session: nil,
       messages: [],
       queued_inputs: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       subagent_roster: %{agents: []},
       runtime_permissions: [],
       user_questions: [],
       heartbeat_notifications: [],
       code_agent_sessions: %{},
       session_status: "idle",
       delete_session: nil,
       show_sidebar: true,
       current_mode: agent_id,
       react_chat: nil,
       react_chat_initial: nil
     )}
  end

  @impl true
  def handle_params(%{"session_id" => session_id} = params, _uri, socket) do
    agent_id = params["agent_id"] || socket.assigns.agent_id
    sessions = load_sessions(agent_id)

    # Unsubscribe from previous session
    if old = socket.assigns.current_session do
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "session:#{old.id}")
    end

    case Sessions.get(session_id) do
      {:ok, session} ->
        Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
        messages = Sessions.get_messages(session.id)
        # ADR-006 B2: the live process is the read authority for current state,
        # so a fresh mount mid-turn shows the in-flight status/text; fall back to
        # the durable/DB status when the process is down.
        {status, in_flight, user_questions, roster, permissions} = live_session_state(session)

        {:noreply,
         assign(socket,
           agent_id: agent_id,
           sessions: sessions,
           current_session: session,
           configured_models: Providers.configured_models(),
           messages: messages,
           queued_inputs: PendingInputStore.queued_prompts(session.id),
           streaming_text: in_flight,
           streaming_reasoning: "",
           tool_calls: %{},
           permission_requests: [],
           subagent_roster: roster,
           runtime_permissions: permissions,
           user_questions: user_questions,
           code_agent_sessions: %{},
           session_status: status,
           current_mode: session.agent || agent_id
         )
         |> start_chat()}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/agent/agents/#{agent_id}/sessions")}

      {:error, reason} ->
        # Storage layer unavailable (e.g. Concord not ready) — degrade instead of
        # crashing the LiveView mount.
        Logger.warning("session_load_failed", session_id: session_id, reason: inspect(reason))

        {:noreply,
         socket
         |> assign(
           agent_id: agent_id,
           sessions: sessions,
           current_session: nil,
           messages: [],
           queued_inputs: [],
           subagent_roster: %{agents: []},
           runtime_permissions: [],
           user_questions: []
         )
         |> put_flash(:error, "Could not load session — storage is temporarily unavailable")
         |> push_navigate(to: ~p"/agent/agents/#{agent_id}/sessions")}
    end
  end

  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    sessions = load_sessions(agent_id)

    if old = socket.assigns.current_session do
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "session:#{old.id}")
    end

    {:noreply,
     assign(socket,
       agent_id: agent_id,
       sessions: sessions,
       current_session: nil,
       messages: [],
       queued_inputs: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       subagent_roster: %{agents: []},
       runtime_permissions: [],
       user_questions: [],
       session_status: "idle",
       react_chat: nil,
       react_chat_initial: nil
     )}
  end

  # ADR-006 B2: resolve status, in-flight text and pending questions from the live read authority
  # (the running session process), falling back to Concord's durable snapshot
  # and finally the DB status. Returns UI status vocabulary ("idle"/"streaming").
  defp live_session_state(session) do
    case Synapsis.Session.Read.live_snapshot(session.id) do
      {:live, %{status: status, in_flight_text: text} = snapshot} ->
        {live_status_string(status), text || "", public_user_questions(snapshot),
         Map.get(snapshot, :subagents, %{agents: []}),
         Map.get(snapshot, :runtime_permissions, [])}

      {:durable, %{meta: %{status: status}}} when is_binary(status) ->
        {status, "", [], %{agents: []}, []}

      _ ->
        {session.status || "idle", "", [], %{agents: []}, []}
    end
  end

  defp live_status_string(:running), do: "streaming"
  defp live_status_string(:waiting), do: "idle"
  defp live_status_string(other), do: to_string(other)

  # --- Events ---

  @max_content_bytes 256_000

  @impl true
  def handle_event(event, params, socket)
      when event in ~w(chat.send chat.stop chat.retry chat.action chat.sync) do
    request_id = params["request_id"]

    cond do
      not ChatBridge.valid_scope?(socket, params) or is_nil(socket.assigns.current_session) ->
        {:reply, %{status: "error", message: "Conversation changed"}, socket}

      not is_nil(request_id) and
          (not is_binary(request_id) or byte_size(request_id) > 128) ->
        {:reply, %{status: "error", message: "Invalid request ID"}, socket}

      true ->
        case ChatBridge.request_reply(socket, request_id) do
          nil ->
            {reply, socket} = chat_event(event, params, socket)
            socket = ChatBridge.remember_request(socket, request_id, reply)
            {:reply, reply, sync_chat(socket)}

          reply ->
            {:reply, reply, socket}
        end
    end
  end

  def handle_event(event, params, socket) do
    {:noreply, socket} = handle_session_event(event, params, socket)
    {:noreply, sync_chat(socket)}
  end

  defp chat_event("chat.sync", _params, socket),
    do:
      {%{status: "ok"},
       socket |> refresh_user_questions() |> sync_chat() |> ChatBridge.snapshot()}

  defp chat_event("chat.send", params, socket) do
    with true <- socket.assigns.react_chat.admission.canSubmit,
         true <- is_binary(params["request_id"]) and params["request_id"] != "",
         {:ok, images} <- Image.decode_payloads(params["images"] || []) do
      submit_message(params["text"], images, socket)
    else
      {:error, {_reason, message}} -> {%{status: "error", message: message}, socket}
      _ -> {%{status: "error", message: "Message cannot be sent"}, socket}
    end
  end

  defp chat_event("chat.stop", _params, socket) do
    if running_session_status?(socket.assigns.session_status) do
      case operation_reply(Sessions.cancel(socket.assigns.current_session.id), socket) do
        {%{status: "ok"} = reply, socket} -> {reply, assign(socket, :user_questions, [])}
        result -> result
      end
    else
      {%{status: "error", message: "Session is not running"}, socket}
    end
  end

  defp chat_event("chat.retry", _params, socket) do
    if socket.assigns.react_chat.admission.canRetry do
      operation_reply(Sessions.retry(socket.assigns.current_session.id), socket)
    else
      {%{status: "error", message: "Session cannot be retried"}, socket}
    end
  end

  defp chat_event("chat.action", %{"action" => "steer", "text" => text}, socket)
       when is_binary(text) do
    text = String.trim(text)

    if running_session_status?(socket.assigns.session_status) and
         socket.assigns.user_questions == [] and text != "" and
         byte_size(text) <= @max_content_bytes do
      operation_reply(Sessions.steer_message(socket.assigns.current_session.id, text), socket)
    else
      {%{status: "error", message: "Session cannot be steered"}, socket}
    end
  end

  defp chat_event(
         "chat.action",
         %{"action" => "answer_question", "ref" => ref, "response" => response} = params,
         socket
       ) do
    valid? =
      is_binary(params["request_id"]) and params["request_id"] != "" and
        is_binary(ref) and ref != "" and byte_size(ref) <= 128 and
        is_binary(response) and String.trim(response) != "" and
        byte_size(response) <= @max_content_bytes

    if valid? do
      case answer_question(socket.assigns.current_session.id, ref, response) do
        :ok ->
          {%{status: "ok"}, refresh_user_questions(socket)}

        {:error, :question_not_pending} ->
          {%{status: "error", message: "Question is no longer pending"},
           refresh_user_questions(socket)}

        _ ->
          {%{status: "error", message: "Question could not be answered"}, socket}
      end
    else
      {%{status: "error", message: "Invalid question response"}, socket}
    end
  end

  defp chat_event("chat.action", %{"action" => "regenerate", "message_id" => id}, socket) do
    valid? = Enum.any?(socket.assigns.messages, &(&1.id == id and &1.role == "assistant"))

    if valid? and socket.assigns.session_status == "idle" and
         not subagents_enabled?(socket.assigns.current_session) do
      case Sessions.regenerate(socket.assigns.current_session.id, id) do
        :ok ->
          {%{status: "ok"},
           assign(socket,
             session_status: "streaming",
             messages: Sessions.get_messages(socket.assigns.current_session.id),
             streaming_text: "",
             streaming_reasoning: "",
             tool_calls: %{}
           )}

        result ->
          operation_reply(result, socket)
      end
    else
      {%{status: "error", message: "Response cannot be regenerated"}, socket}
    end
  end

  defp chat_event(
         "chat.action",
         %{"action" => action, "tool_use_id" => id, "message_id" => message_id},
         socket
       )
       when action in ~w(approve_tool deny_tool) do
    valid? =
      message_id == SessionChat.live_id(socket.assigns.current_session.id) and
        Enum.any?(socket.assigns.permission_requests, &(&1.tool_use_id == id))

    if valid? do
      result =
        if action == "approve_tool",
          do: Sessions.approve_tool(socket.assigns.current_session.id, id),
          else: Sessions.deny_tool(socket.assigns.current_session.id, id)

      case operation_reply(result, socket) do
        {%{status: "ok"} = reply, socket} ->
          {reply,
           update(
             socket,
             :permission_requests,
             &Enum.reject(&1, fn request -> request.tool_use_id == id end)
           )}

        result ->
          result
      end
    else
      {%{status: "error", message: "Permission request is no longer pending"}, socket}
    end
  end

  defp chat_event("chat.action", %{"action" => "dismiss_heartbeat", "message_id" => id}, socket) do
    if Enum.any?(socket.assigns.heartbeat_notifications, &("heartbeat-#{&1.id}" == id)) do
      {%{status: "ok"},
       update(
         socket,
         :heartbeat_notifications,
         &Enum.reject(&1, fn notification -> "heartbeat-#{notification.id}" == id end)
       )}
    else
      {%{status: "error", message: "Notification is no longer available"}, socket}
    end
  end

  defp chat_event(_event, _params, socket),
    do: {%{status: "error", message: "Unsupported chat action"}, socket}

  defp operation_reply(:ok, socket), do: {%{status: "ok"}, socket}
  defp operation_reply({:ok, _result}, socket), do: {%{status: "ok"}, socket}

  defp operation_reply(_result, socket),
    do: {%{status: "error", message: "Session action failed"}, socket}

  defp handle_session_event("switch_model", %{"model_id" => id}, socket) do
    models = Providers.configured_models()
    socket = assign(socket, configured_models: models)
    model = Enum.find(models, &(&1.id == id))

    cond do
      is_nil(socket.assigns.current_session) ->
        {:noreply, put_flash(socket, :error, "Select a session first")}

      running_session_status?(socket.assigns.session_status) ->
        {:noreply,
         put_flash(socket, :error, "Wait for the session to become idle before switching models")}

      is_nil(model) ->
        {:noreply, put_flash(socket, :error, "Selected model is unavailable")}

      true ->
        case Sessions.switch_model(socket.assigns.current_session.id, model.provider, model.model) do
          :ok ->
            {:noreply,
             socket
             |> maybe_refresh_current_session()
             |> put_flash(:info, "Session model updated")}

          {:error, :session_busy} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Wait for the session to become idle before switching models"
             )}

          {:error, {:history_incompatible, _reason}} ->
            {:noreply, put_flash(socket, :error, "Session history cannot be sent to this model")}

          {:error, :db_update_failed} ->
            {:noreply, put_flash(socket, :error, "Failed to save the session model")}

          {:error, reason} when reason in [:model_unavailable, :provider_unavailable] ->
            {:noreply, put_flash(socket, :error, "Selected model is unavailable")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to switch session model")}
        end
    end
  end

  defp handle_session_event("toggle_subagents", _params, socket) do
    case socket.assigns.current_session do
      nil ->
        {:noreply, socket}

      session ->
        case Worker.set_subagents(session.id, not subagents_enabled?(session)) do
          {:ok, updated} ->
            {:noreply, assign(socket, :current_session, updated)}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Subagents can be changed when the session and its agents are idle"
             )}
        end
    end
  end

  defp handle_session_event(
         "resolve_runtime_permission",
         %{"interaction-id" => id, "decision" => decision},
         socket
       )
       when decision in ["allow", "deny"] do
    pending? = Enum.any?(socket.assigns.runtime_permissions, &(&1.interaction_id == id))

    if socket.assigns.current_session && pending? do
      case Worker.resolve_runtime(socket.assigns.current_session.id, id, decision == "allow") do
        :ok ->
          {:noreply,
           update(
             socket,
             :runtime_permissions,
             &Enum.reject(&1, fn pending -> pending.interaction_id == id end)
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "This approval is no longer available")}
      end
    else
      {:noreply, put_flash(socket, :error, "This approval is no longer available")}
    end
  end

  defp handle_session_event("resolve_runtime_permission", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid approval decision")}

  defp handle_session_event("send_message", %{"value" => content, "images" => images}, socket) do
    send_message_with_images(content, images, socket)
  end

  defp handle_session_event("send_message", %{"content" => content, "images" => images}, socket) do
    send_message_with_images(content, images, socket)
  end

  defp handle_session_event("send_message", %{"value" => content}, socket) do
    send_message(content, [], socket)
  end

  defp handle_session_event("send_message", %{"content" => content}, socket) do
    send_message(content, [], socket)
  end

  defp handle_session_event("image_attachment_error", _params, socket) do
    {:noreply, put_flash(socket, :error, "Could not read image attachment")}
  end

  defp handle_session_event("steer_message", %{"value" => content}, socket) do
    steer_message(content, socket)
  end

  defp handle_session_event("steer_message", %{"content" => content}, socket) do
    steer_message(content, socket)
  end

  defp handle_session_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  defp handle_session_event("create_session", _params, socket) do
    agent_id = socket.assigns.agent_id
    # Re-resolve to pick up any config changes saved from the setting page
    agent_config = Synapsis.Agent.Resolver.resolve(agent_id)
    provider = agent_config.provider || "anthropic"
    model = agent_config.model || Synapsis.Providers.default_model(provider)

    case Sessions.create(agent_id, %{provider: provider, model: model, agent: agent_id}) do
      {:ok, session} ->
        sessions = [session | socket.assigns.sessions]

        {:noreply,
         socket
         |> assign(sessions: sessions)
         |> push_patch(to: ~p"/agent/agents/#{agent_id}/sessions/#{session.id}")}

      {:error, reason} ->
        Logger.warning("session_create_failed", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  defp handle_session_event("switch_session", %{"id" => session_id}, socket) do
    agent_id = socket.assigns.agent_id
    {:noreply, push_patch(socket, to: ~p"/agent/agents/#{agent_id}/sessions/#{session_id}")}
  end

  defp handle_session_event("confirm_delete_session", %{"id" => session_id}, socket) do
    delete_session = Enum.find(socket.assigns.sessions, &(&1.id == session_id))
    {:noreply, assign(socket, :delete_session, delete_session)}
  end

  defp handle_session_event("cancel_delete_session", _params, socket) do
    {:noreply, assign(socket, :delete_session, nil)}
  end

  defp handle_session_event("delete_session", %{"id" => session_id}, socket) do
    agent_id = socket.assigns.agent_id

    case Sessions.delete(session_id) do
      {:ok, _session_id} ->
        sessions = Enum.reject(socket.assigns.sessions, &(&1.id == session_id))
        socket = assign(socket, sessions: sessions, delete_session: nil)

        if socket.assigns.current_session && socket.assigns.current_session.id == session_id do
          {:noreply,
           socket
           |> push_navigate(to: ~p"/agent/agents/#{agent_id}/sessions")}
        else
          {:noreply, socket}
        end

      {:error, :not_found} ->
        sessions = Enum.reject(socket.assigns.sessions, &(&1.id == session_id))

        {:noreply,
         socket
         |> assign(sessions: sessions, delete_session: nil)
         |> put_flash(:error, "Session not found")}

      {:error, reason} ->
        Logger.warning("session_delete_failed", session_id: session_id, reason: inspect(reason))

        {:noreply,
         socket
         |> assign(:delete_session, nil)
         |> put_flash(:error, "Failed to delete session")}
    end
  end

  defp handle_session_event("cancel_stream", _params, socket) do
    if session = socket.assigns.current_session do
      Sessions.cancel(session.id)
    end

    {:noreply, assign(socket, :user_questions, [])}
  end

  defp handle_session_event("retry", _params, socket) do
    if session = socket.assigns.current_session do
      Sessions.retry(session.id)
    end

    {:noreply, socket}
  end

  defp handle_session_event("regenerate", %{"id" => message_id}, socket) do
    case socket.assigns.current_session do
      nil ->
        {:noreply, socket}

      session ->
        socket =
          socket
          |> assign(:session_status, "streaming")
          |> assign(:tool_calls, %{})

        case Sessions.regenerate(session.id, message_id) do
          :ok ->
            {:noreply, assign(socket, :messages, Sessions.get_messages(session.id))}

          {:error, reason} ->
            Logger.warning("session_regenerate_failed",
              session_id: session.id,
              reason: inspect(reason)
            )

            {:noreply,
             socket
             |> assign(:session_status, "idle")
             |> assign(:messages, Sessions.get_messages(session.id))
             |> put_flash(:error, "Could not regenerate response")}
        end
    end
  end

  defp handle_session_event("approve_tool", %{"tool-use-id" => tool_use_id}, socket) do
    if session = socket.assigns.current_session do
      Sessions.approve_tool(session.id, tool_use_id)
    end

    requests = Enum.reject(socket.assigns.permission_requests, &(&1.tool_use_id == tool_use_id))
    {:noreply, assign(socket, :permission_requests, requests)}
  end

  defp handle_session_event("deny_tool", %{"tool-use-id" => tool_use_id}, socket) do
    if session = socket.assigns.current_session do
      Sessions.deny_tool(session.id, tool_use_id)
    end

    requests = Enum.reject(socket.assigns.permission_requests, &(&1.tool_use_id == tool_use_id))
    {:noreply, assign(socket, :permission_requests, requests)}
  end

  defp handle_session_event("dismiss_heartbeat", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        {:noreply,
         update(socket, :heartbeat_notifications, fn notifs ->
           Enum.reject(notifs, &(&1.id == id))
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_session_event("switch_mode", %{"mode" => mode}, socket) do
    if session = socket.assigns.current_session do
      Sessions.switch_mode(session.id, mode)
    end

    {:noreply, assign(socket, :current_mode, mode)}
  end

  defp send_message_with_images(content, images, socket) do
    case Image.decode_payloads(images) do
      {:ok, image_parts} -> send_message(content, image_parts, socket)
      {:error, {_reason, message}} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp send_message(content, image_parts, socket) do
    {_reply, socket} = submit_message(content, image_parts, socket)
    {:noreply, socket}
  end

  defp submit_message(content, image_parts, socket)
       when is_binary(content) and is_list(image_parts) do
    content = String.trim(content)

    cond do
      (content == "" and image_parts == []) or is_nil(socket.assigns.current_session) ->
        {%{status: "error", message: "Enter a message or attach an image"}, socket}

      byte_size(content) > @max_content_bytes ->
        {%{status: "error", message: "Message too large"},
         put_flash(socket, :error, "Message too large")}

      true ->
        session_id = socket.assigns.current_session.id
        running? = running_session_status?(socket.assigns.session_status)

        socket =
          if running? do
            socket
          else
            # Optimistic update: show the user message immediately for a new turn.
            optimistic_msg = %Synapsis.Message{
              id: Ecto.UUID.generate(),
              session_id: session_id,
              role: "user",
              parts: optimistic_user_parts(content, image_parts),
              inserted_at: DateTime.utc_now()
            }

            socket
            |> update(:messages, &(&1 ++ [optimistic_msg]))
            |> assign(:session_status, "streaming")
            |> assign(:tool_calls, %{})
          end

        case Sessions.send_message(session_id, content, image_parts) do
          :ok ->
            socket =
              if running? or subagents_enabled?(socket.assigns.current_session) do
                socket
              else
                # Reload from DB to get the real persisted message with correct ID/timestamps
                assign(socket, :messages, Sessions.get_messages(session_id))
              end

            {%{status: "ok"}, push_event(socket, "clear_chat_input", %{})}

          {:error, reason} ->
            Logger.warning("session_send_failed", session_id: session_id, reason: inspect(reason))

            if running? do
              {%{status: "error", message: "Failed to queue message"},
               put_flash(socket, :error, "Failed to queue message")}
            else
              {%{status: "error", message: "Failed to send message"},
               socket
               |> assign(:messages, Sessions.get_messages(session_id))
               |> assign(:session_status, "error")
               |> put_flash(:error, "Failed to send message")}
            end
        end
    end
  end

  defp submit_message(_content, _image_parts, socket),
    do: {%{status: "error", message: "Invalid message"}, socket}

  defp optimistic_user_parts("", [_image | _] = image_parts), do: image_parts

  defp optimistic_user_parts(content, image_parts),
    do: [%Synapsis.Part.Text{content: content} | image_parts]

  defp steer_message(content, socket) when is_binary(content) do
    content = String.trim(content)

    cond do
      content == "" or is_nil(socket.assigns.current_session) ->
        {:noreply, socket}

      not running_session_status?(socket.assigns.session_status) or
          socket.assigns.user_questions != [] ->
        {:noreply, socket}

      byte_size(content) > @max_content_bytes ->
        {:noreply, put_flash(socket, :error, "Message too large")}

      true ->
        session_id = socket.assigns.current_session.id

        case Sessions.steer_message(session_id, content) do
          :ok ->
            {:noreply, socket}

          {:error, reason} ->
            Logger.warning("session_steer_failed",
              session_id: session_id,
              reason: inspect(reason)
            )

            {:noreply, put_flash(socket, :error, "Failed to steer session")}
        end
    end
  end

  defp steer_message(_content, socket), do: {:noreply, socket}

  # --- PubSub handle_info ---

  @impl true
  def handle_info({"text_delta", %{text: text}}, socket) when is_binary(text) do
    if socket.assigns.current_session do
      socket = sync_chat(socket)
      id = SessionChat.live_id(socket.assigns.current_session.id)

      socket =
        if Enum.any?(socket.assigns.react_chat.messages, &(&1.id == id)) do
          socket
        else
          socket |> assign(:session_status, "streaming") |> sync_chat()
        end

      {:noreply,
       socket
       |> update(:streaming_text, &(&1 <> text))
       |> ChatBridge.delta(id, text)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(message, socket) do
    {:noreply, socket} = handle_session_info(message, socket)
    {:noreply, sync_chat(socket)}
  end

  defp handle_session_info({:ask_user, _ref, payload}, socket) do
    case socket.assigns.current_session do
      %{id: id} when not is_map_key(payload, :session_id) or payload.session_id == id ->
        {:noreply, refresh_user_questions(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_session_info({:ask_user_closed, _ref}, socket),
    do: {:noreply, refresh_user_questions(socket)}

  defp handle_session_info({"reasoning", %{text: text}}, socket) do
    {:noreply, update(socket, :streaming_reasoning, &(&1 <> text))}
  end

  defp handle_session_info({"tool_use", %{tool: name, tool_use_id: id} = payload}, socket) do
    tool_calls =
      Map.put(socket.assigns.tool_calls, id, %{
        name: name,
        status: "running",
        input: payload[:input] || %{},
        result: nil
      })

    {:noreply, assign(socket, :tool_calls, tool_calls)}
  end

  defp handle_session_info({"tool_result", %{tool_use_id: id} = payload}, socket) do
    status = if payload[:is_error], do: "error", else: "complete"

    tool_calls =
      Map.update(
        socket.assigns.tool_calls,
        id,
        %{status: status, result: payload[:content]},
        fn tc -> Map.merge(tc, %{status: status, result: payload[:content]}) end
      )

    {:noreply, assign(socket, :tool_calls, tool_calls)}
  end

  defp handle_session_info({"permission_request", payload}, socket) do
    {:noreply, update(socket, :permission_requests, &[payload | &1])}
  end

  defp handle_session_info({"subagents", roster}, socket) when is_map(roster) do
    {:noreply, assign(socket, :subagent_roster, roster)}
  end

  defp handle_session_info({"runtime_permissions", pending}, socket) when is_list(pending) do
    {:noreply, assign(socket, :runtime_permissions, pending)}
  end

  defp handle_session_info({"permission_requests", %{tools: tools}}, socket)
       when is_list(tools) do
    {:noreply, update(socket, :permission_requests, &(tools ++ &1))}
  end

  defp handle_session_info({"input_queued", %{id: id, kind: "prompt", content: content}}, socket) do
    queued =
      if session = socket.assigns.current_session do
        Enum.find(PendingInputStore.queued_prompts(session.id), &(&1.id == id))
      end

    queued = queued || %{id: id, kind: "prompt", content: content}
    {:noreply, update(socket, :queued_inputs, &append_unique_input(&1, queued))}
  end

  defp handle_session_info({"input_queued", %{kind: "steer"}}, socket) do
    {:noreply, socket}
  end

  defp handle_session_info({"input_started", %{id: id}}, socket) do
    {:noreply, update(socket, :queued_inputs, &Enum.reject(&1, fn input -> input.id == id end))}
  end

  defp handle_session_info({"done", _}, socket) do
    name = socket.assigns.agent_id

    messages =
      if session = socket.assigns.current_session do
        Sessions.get_messages(session.id)
      else
        []
      end

    sessions = load_sessions(name)

    # Keep tool calls with error status visible so failed tools remain in chat
    error_tool_calls =
      socket.assigns.tool_calls
      |> Enum.filter(fn {_id, tc} -> tc[:status] == "error" end)
      |> Map.new()

    {:noreply,
     assign(socket,
       messages: messages,
       sessions: sessions,
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: error_tool_calls,
       permission_requests: [],
       user_questions: [],
       session_status: "idle"
     )}
  end

  defp handle_session_info({"session_status", %{status: status}}, socket) do
    {:noreply, assign_session_status(socket, status)}
  end

  defp handle_session_info({"error", %{message: msg}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, msg)
     |> assign_session_status("error")}
  end

  defp handle_session_info({"agent_switched", %{agent: agent}}, socket) do
    {:noreply, assign(socket, :current_mode, agent)}
  end

  defp handle_session_info({"model_switched", _payload}, socket) do
    if session = socket.assigns.current_session do
      case Sessions.get(session.id) do
        {:ok, updated} ->
          {:noreply,
           assign(socket,
             current_session: updated,
             configured_models: Providers.configured_models()
           )}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_session_info({"mode_switched", %{agent: agent}}, socket) do
    {:noreply, assign(socket, :current_mode, agent)}
  end

  defp handle_session_info({"auditing", _payload}, socket), do: {:noreply, socket}

  defp handle_session_info({:session_compacted, session_id, _metadata}, socket) do
    messages =
      case socket.assigns.current_session do
        %{id: ^session_id} -> Sessions.get_messages(session_id, limit: 200)
        _ -> socket.assigns.messages
      end

    {:noreply, assign(socket, :messages, messages)}
  end

  defp handle_session_info({:system_message, %{type: :compaction} = payload}, socket) do
    {:noreply, put_flash(socket, :info, payload.text)}
  end

  defp handle_session_info(
         {:heartbeat_completed, _config_id, %{name: name, executed_at: ts, result: result}},
         socket
       ) do
    notification = %{
      name: name,
      timestamp: ts,
      result: String.slice(result || "", 0, 500),
      id: System.unique_integer([:positive])
    }

    {:noreply,
     update(socket, :heartbeat_notifications, fn notifs ->
       [notification | notifs] |> Enum.take(10)
     end)}
  end

  defp handle_session_info(
         {"code_agent_spawned", %{sub_session_id: sub_id, prompt: prompt}},
         socket
       ) do
    entry = %{prompt: prompt, status: "running", tool_calls: [], completion: nil}
    {:noreply, update(socket, :code_agent_sessions, &Map.put(&1, sub_id, entry))}
  end

  defp handle_session_info(
         {"code_agent_event", %{sub_session_id: sub_id, event: event, payload: payload}},
         socket
       ) do
    {:noreply, update_code_agent(socket, sub_id, event, payload)}
  end

  defp handle_session_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full">
      <%!-- Mobile sidebar toggle --%>
      <.dm_btn
        variant="ghost"
        phx-click="toggle_sidebar"
        class="md:hidden fixed top-16 left-2 z-20"
      >
        <.dm_mdi name={if(@show_sidebar, do: "close", else: "menu")} class="w-5 h-5" />
      </.dm_btn>

      <%!-- Sidebar --%>
      <aside
        class={[
          "w-72 bg-surface-container text-on-surface border-r border-outline-variant flex flex-col shrink-0 transition-transform shadow-lg md:shadow-none",
          "fixed md:relative inset-y-0 left-0 z-10 md:z-auto md:translate-x-0 pt-16 md:pt-0",
          if(@show_sidebar, do: "translate-x-0", else: "-translate-x-full")
        ]}
        data-agent-session-sidebar
      >
        <%!-- Agent header --%>
        <div class="px-4 py-3 border-b border-outline-variant bg-surface-container-high">
          <div class="flex items-center justify-between gap-2">
            <.dm_link
              navigate={~p"/agent/agents"}
              class="inline-flex items-center gap-1 text-xs text-on-surface-variant hover:text-on-surface transition-colors"
            >
              <.dm_mdi name="chevron-left" class="w-3.5 h-3.5" /> Agents
            </.dm_link>
            <.dm_link
              navigate={~p"/agent/agents/#{@agent_id}/config"}
              aria-label="Agent settings"
              class="inline-flex h-8 w-8 items-center justify-center rounded-md text-on-surface-variant hover:bg-surface-container-highest hover:text-on-surface transition-colors"
            >
              <.dm_mdi name="cog-outline" class="w-4 h-4" />
            </.dm_link>
          </div>

          <div class="mt-3 flex items-center gap-3 min-w-0">
            <div class="h-10 w-10 rounded-md bg-primary-container text-on-primary-container flex items-center justify-center shrink-0">
              <.dm_mdi name={@agent_config.icon || "robot-happy-outline"} class="w-5 h-5" />
            </div>
            <div class="min-w-0">
              <h2 class="text-sm font-semibold truncate">
                {agent_display_name(@agent_config, @agent_id)}
              </h2>
              <p class="text-xs text-on-surface-variant truncate">
                <%= if @provider_configured do %>
                  Ready to chat
                <% else %>
                  Provider not configured
                <% end %>
              </p>
            </div>
          </div>

          <%= if @provider_configured do %>
            <.dm_btn variant="primary" class="w-full mt-3" phx-click="create_session">
              <.dm_mdi name="plus" class="w-4 h-4" /> New Session
            </.dm_btn>
          <% else %>
            <.dm_tooltip
              content="Set a provider in agent config first"
              position="bottom"
              color="warning"
            >
              <.dm_btn variant="ghost" class="w-full mt-3 opacity-60 cursor-not-allowed" disabled>
                <.dm_mdi name="plus" class="w-4 h-4" /> New Session
              </.dm_btn>
            </.dm_tooltip>
          <% end %>
        </div>

        <%!-- Session list --%>
        <div class="px-4 py-2 border-b border-outline-variant flex items-center justify-between text-xs text-on-surface-variant">
          <span>Sessions</span>
          <span class="font-mono">{length(@sessions)}</span>
        </div>
        <nav class="flex-1 overflow-y-auto p-2 space-y-1" aria-label="Agent sessions">
          <.session_list_item
            :for={session <- @sessions}
            session={session}
            active={@current_session != nil && session.id == @current_session.id}
          />
          <.empty_state
            :if={@sessions == []}
            icon="chat-outline"
            title="No sessions"
            description="Create a new session to get started"
            class="py-8"
          />
        </nav>
      </aside>

      <%!-- Main chat area --%>
      <main class="flex-1 min-w-0 flex flex-col">
        <%= if @current_session do %>
          <%!-- Session header --%>
          <div class="flex items-center justify-between border-b border-outline-variant bg-surface-container-low px-4 py-3">
            <div class="flex items-center gap-3 min-w-0">
              <.dm_mdi
                name={@agent_config.icon || "robot-happy-outline"}
                class="w-5 h-5 text-primary shrink-0"
              />
              <div class="min-w-0">
                <h2 class="font-medium text-sm truncate">
                  {@current_session.title ||
                    "Session #{String.slice(@current_session.id || "", 0..7)}"}
                </h2>
                <div class="text-xs text-on-surface-variant">
                  <span class="text-primary/70" data-session-agent-meta>
                    {@agent_config.label || String.capitalize(@agent_id)}
                  </span>
                </div>
              </div>
            </div>
            <div class="flex items-center gap-2 flex-wrap justify-end">
              <.session_model_selector
                session={@current_session}
                models={@configured_models}
                busy={running_session_status?(@session_status)}
              />
              <.dm_btn
                id="session-subagents-toggle"
                variant={if(subagents_enabled?(@current_session), do: "secondary", else: "ghost")}
                size="xs"
                phx-click="toggle_subagents"
                aria-pressed={to_string(subagents_enabled?(@current_session))}
                disabled={subagents_busy?(@session_status, @subagent_roster)}
              >
                Subagents {if(subagents_enabled?(@current_session), do: "enabled", else: "disabled")}
              </.dm_btn>
              <.dm_btn
                :if={@session_status == "error" and not subagents_enabled?(@current_session)}
                variant="ghost"
                size="xs"
                phx-click="retry"
              >
                <.dm_mdi name="refresh" class="w-4 h-4" /> Retry
              </.dm_btn>
              <.dm_btn
                :if={@session_status in ~w(streaming tool_executing)}
                variant="ghost"
                size="xs"
                phx-click="cancel_stream"
              >
                <.dm_mdi name="stop" class="w-4 h-4" /> Cancel
              </.dm_btn>
            </div>
          </div>

          <.subagents_panel
            :if={
              subagents_enabled?(@current_session) || @subagent_roster.agents != [] ||
                @runtime_permissions != [] || subagents_need_attention?(@subagent_roster)
            }
            roster={@subagent_roster}
            permissions={@runtime_permissions}
          />

          <.dm_react_chat
            id={@react_chat_initial.id}
            conversation_id={@react_chat_initial.conversation_id}
            messages={@react_chat_initial.messages}
            metadata={@react_chat_initial.metadata}
            runtime={@react_chat_initial.runtime}
            admission={@react_chat_initial.admission}
            label={@react_chat_initial.metadata.assistantLabel}
            hook="SynapsisReactChat"
            class="synapsis-react-chat flex min-h-0 flex-1 flex-col"
          />

          <%!-- Status bar --%>
          <.session_status_bar
            current_mode={@current_mode}
            session_status={@session_status}
            context_label={session_context_size_label(@messages)}
            model_label={session_model_label(@current_session)}
            on_mode_change="switch_mode"
            has_session={true}
          />
        <% else %>
          <%!-- Empty state --%>
          <div class="flex-1 flex items-center justify-center">
            <.empty_state
              icon="robot-outline"
              title={"#{String.capitalize(@agent_id)} Agent"}
              description={
                if @provider_configured,
                  do: "Create or select a session to start chatting",
                  else: "Configure a provider in settings to start chatting"
              }
            >
              <:action>
                <%= if @provider_configured do %>
                  <.dm_btn variant="secondary" phx-click="create_session">
                    <.dm_mdi name="plus" class="w-4 h-4" /> New Session
                  </.dm_btn>
                <% else %>
                  <.dm_link navigate={~p"/agent/agents/#{@agent_id}/config"}>
                    <.dm_btn variant="secondary">
                      <.dm_mdi name="cog-outline" class="w-4 h-4" /> Go to Settings
                    </.dm_btn>
                  </.dm_link>
                <% end %>
              </:action>
            </.empty_state>
          </div>
        <% end %>
      </main>

      <div
        :if={@delete_session}
        id="delete-session-modal"
        class="fixed inset-0 z-50 flex items-center justify-center px-4 py-6"
        role="presentation"
      >
        <button
          type="button"
          class="absolute inset-0 bg-scrim/50"
          aria-label="Cancel delete session"
          phx-click="cancel_delete_session"
        ></button>
        <section
          role="dialog"
          aria-modal="true"
          aria-labelledby="delete-session-title"
          class="relative w-full max-w-sm rounded-md border border-outline-variant bg-surface-container-high text-on-surface shadow-xl"
        >
          <div class="flex items-start gap-3 border-b border-outline-variant p-4">
            <div class="mt-0.5 rounded-md bg-error-container p-2 text-on-error-container">
              <.dm_mdi name="delete-outline" class="h-5 w-5" />
            </div>
            <div class="min-w-0">
              <h2 id="delete-session-title" class="text-base font-semibold">Delete session?</h2>
              <p class="mt-1 text-sm text-on-surface-variant">
                This removes <span class="font-medium text-on-surface">{session_title(@delete_session)}</span>.
              </p>
            </div>
          </div>
          <div class="flex justify-end gap-2 p-4">
            <.dm_btn variant="ghost" phx-click="cancel_delete_session">
              Cancel
            </.dm_btn>
            <.dm_btn variant="error" phx-click="delete_session" phx-value-id={@delete_session.id}>
              Delete
            </.dm_btn>
          </div>
        </section>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp start_chat(socket) do
    session_id = socket.assigns.current_session.id

    ChatBridge.start(
      socket,
      "agent-chat-#{session_id}",
      session_id,
      SessionChat.snapshot(socket.assigns)
    )
  end

  defp sync_chat(%{assigns: %{current_session: nil}} = socket), do: socket

  defp sync_chat(socket) do
    ChatBridge.sync(socket, SessionChat.snapshot(socket.assigns))
  end

  defp refresh_user_questions(%{assigns: %{current_session: nil}} = socket),
    do: assign(socket, :user_questions, [])

  defp refresh_user_questions(socket) do
    questions =
      case Synapsis.Session.Read.live_snapshot(socket.assigns.current_session.id) do
        {:live, snapshot} -> public_user_questions(snapshot)
        _ -> []
      end

    assign(socket, :user_questions, questions)
  end

  defp public_user_questions(snapshot) do
    snapshot
    |> Map.get(:user_questions, [])
    |> Enum.map(&Map.take(&1, [:ref, :question, :options]))
  end

  defp answer_question(session_id, ref, response) do
    Worker.answer_question(session_id, ref, response)
  catch
    :exit, _ -> {:error, :question_not_pending}
  end

  defp load_sessions(agent_name) do
    {:ok, sessions} = Sessions.list(agent_name, limit: 50)
    sessions
  end

  defp session_title(%{title: title}) when is_binary(title) and title != "", do: title

  defp session_title(%{id: id}) when is_binary(id) do
    "Session #{String.slice(id, 0..7)}"
  end

  defp session_title(_session), do: "this session"

  defp agent_display_name(agent_config, agent_id) do
    base =
      case agent_config do
        %{label: label} when label not in [nil, ""] -> label
        _ -> String.capitalize(agent_id)
      end

    if String.ends_with?(base, "Agent"), do: base, else: "#{base} Agent"
  end

  defp assign_session_status(socket, status) when status in ~w(streaming tool_executing) do
    case fetch_current_session(socket) do
      {:ok, %{status: terminal_status} = session} when terminal_status in ~w(idle error) ->
        socket
        |> assign(:current_session, session)
        |> clear_transient_generation()
        |> assign(:session_status, terminal_status)

      _ ->
        assign(socket, :session_status, status)
    end
  end

  defp assign_session_status(socket, status) when status in ~w(idle error) do
    messages =
      if session = socket.assigns.current_session do
        Sessions.get_messages(session.id)
      else
        []
      end

    socket
    |> maybe_refresh_current_session()
    |> clear_transient_generation()
    |> assign(:messages, messages)
    |> assign(:session_status, status)
  end

  defp assign_session_status(socket, status), do: assign(socket, :session_status, status)

  defp maybe_refresh_current_session(socket) do
    case fetch_current_session(socket) do
      {:ok, session} -> assign(socket, :current_session, session)
      _ -> socket
    end
  end

  defp fetch_current_session(%{assigns: %{current_session: %{id: id}}}) do
    Sessions.get(id)
  end

  defp fetch_current_session(_socket), do: {:error, :not_found}

  attr :session, :map, required: true
  attr :models, :list, required: true
  attr :busy, :boolean, required: true

  defp session_model_selector(assigns) do
    saved_id = (assigns.session.config || %{})["model_id"]

    selected =
      Enum.find(assigns.models, fn model ->
        if saved_id,
          do: model.id == saved_id,
          else:
            model.provider == assigns.session.provider and model.model == assigns.session.model
      end)

    groups = assigns.models |> Enum.group_by(& &1.provider) |> Enum.sort_by(&elem(&1, 0))
    assigns = assign(assigns, selected: selected, model_groups: groups)

    ~H"""
    <form id="session-model-form" phx-change="switch_model" class="min-w-48 max-w-xs">
      <.dm_select
        id="session-model-selector"
        name="model_id"
        label="Session model"
        size="sm"
        disabled={@busy}
        helper={
          if @selected,
            do: "#{@selected.context_window} context tokens",
            else: "Current model unavailable; select an available model"
        }
      >
        <option :if={is_nil(@selected)} value="" selected disabled>
          {@session.provider}/{@session.model} (unavailable)
        </option>
        <optgroup :for={{provider, models} <- @model_groups} label={provider}>
          <option
            :for={model <- models}
            value={model.id}
            selected={@selected && @selected.id == model.id}
          >
            {model.name}
          </option>
        </optgroup>
      </.dm_select>
    </form>
    """
  end

  defp running_session_status?(status), do: status in @running_statuses

  defp session_context_size_label(messages) when is_list(messages) do
    tokens = ContextWindow.total_tokens(messages)
    "#{format_context_tokens(tokens)} #{token_unit(tokens)}"
  end

  defp session_context_size_label(_messages), do: "0 tokens"

  attr :roster, :map, required: true
  attr :permissions, :list, required: true

  defp subagents_panel(assigns) do
    ~H"""
    <section
      id="session-subagents"
      aria-label="Subagents"
      class="max-h-72 overflow-y-auto border-b border-outline-variant px-4 py-2"
    >
      <.dm_card variant="bordered" padding="sm" body_class="space-y-2">
        <div class="flex items-center justify-between gap-2 text-xs">
          <h3 class="font-semibold">Subagents</h3>
          <span class="text-on-surface-variant">{length(@roster.agents)} agents</span>
        </div>
        <div :if={subagents_need_attention?(@roster)} role="status" class="text-xs space-y-1">
          <.dm_badge variant="warning" size="sm">Recovery required</.dm_badge>
          <p>
            <%= if @roster[:error] == :storage_unavailable do %>
              Agent status is temporarily unavailable.
            <% else %>
              Some agent work could not be confirmed. Subagents are unavailable until the session is recovered.
            <% end %>
          </p>
          <p :if={@roster[:root]} class="text-on-surface-variant">
            Session work: {subagent_status(@roster.root.status)}
          </p>
        </div>
        <p
          :if={@roster.agents == [] && not subagents_need_attention?(@roster)}
          class="text-xs text-on-surface-variant"
        >
          The assistant can delegate tasks to agents in this session.
        </p>
        <ul :if={@roster.agents != []} class="flex flex-wrap gap-2" aria-label="Session agents">
          <li
            :for={agent <- @roster.agents}
            class="flex items-center gap-2 rounded-md bg-surface-container px-2 py-1 text-xs"
          >
            <span class="font-medium">{agent.name}</span>
            <.dm_badge size="sm">{subagent_status(agent.status)}</.dm_badge>
            <span :if={agent[:historical] == true} class="text-on-surface-variant">Historical</span>
          </li>
        </ul>
        <div
          :for={pending <- @permissions}
          data-runtime-permission={pending.interaction_id}
          class="rounded-md border border-outline-variant p-2 text-xs space-y-2"
        >
          <p>
            <span class="font-semibold">{approval_agent_name(pending)}</span>
            requests permission to use <span class="font-mono">{pending.request.tool_name}</span>
          </p>
          <pre class="max-h-24 overflow-auto whitespace-pre-wrap break-all text-on-surface-variant">{Jason.encode!(pending.request.arguments, pretty: true)}</pre>
          <div class="flex gap-2">
            <.dm_btn
              variant="primary"
              size="xs"
              phx-click="resolve_runtime_permission"
              phx-value-interaction-id={pending.interaction_id}
              phx-value-decision="allow"
            >
              Allow
            </.dm_btn>
            <.dm_btn
              variant="ghost"
              size="xs"
              phx-click="resolve_runtime_permission"
              phx-value-interaction-id={pending.interaction_id}
              phx-value-decision="deny"
            >
              Deny
            </.dm_btn>
          </div>
        </div>
      </.dm_card>
    </section>
    """
  end

  defp subagents_enabled?(session), do: Synapsis.Session.subagents_enabled?(session)

  defp subagents_busy?(status, roster) do
    subagents_need_attention?(roster) || running_session_status?(status) ||
      Enum.any?(roster.agents, fn agent ->
        to_string(agent.status) not in ~w(completed errored interrupted closed shutdown)
      end)
  end

  defp subagents_need_attention?(roster) do
    roster[:recovery_required] == true || not is_nil(roster[:error]) ||
      get_in(roster, [:root, :status]) in [:unknown_outcome, "unknown_outcome"]
  end

  defp subagent_status(status) when status in [:unknown_outcome, "unknown_outcome"],
    do: "Needs attention"

  defp subagent_status(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp approval_agent_name(%{child: %{name: "/root"}}), do: "Assistant"
  defp approval_agent_name(%{child: %{name: name}}), do: name
  defp approval_agent_name(_), do: "Assistant"

  defp session_model_label(%{model: model}) when is_binary(model) and model != "", do: model
  defp session_model_label(_session), do: nil

  defp format_context_tokens(tokens) when tokens >= 1_000_000 do
    compact_number(tokens / 1_000_000, "M")
  end

  defp format_context_tokens(tokens) when tokens >= 1_000 do
    compact_number(tokens / 1_000, "K")
  end

  defp format_context_tokens(tokens), do: Integer.to_string(tokens)

  defp compact_number(value, suffix) do
    rounded = Float.round(value, 1)

    formatted =
      if rounded == trunc(rounded) do
        Integer.to_string(trunc(rounded))
      else
        :erlang.float_to_binary(rounded, decimals: 1)
      end

    formatted <> suffix
  end

  defp token_unit(1), do: "token"
  defp token_unit(_count), do: "tokens"

  defp clear_transient_generation(socket) do
    # Preserve tool calls with error status so failed tools remain visible in chat
    error_tool_calls =
      socket.assigns.tool_calls
      |> Enum.filter(fn {_id, tc} -> tc[:status] == "error" end)
      |> Map.new()

    assign(socket,
      streaming_text: "",
      streaming_reasoning: "",
      tool_calls: error_tool_calls,
      permission_requests: [],
      user_questions: []
    )
  end

  defp append_unique_input(inputs, queued) do
    if Enum.any?(inputs, &(&1.id == queued.id)), do: inputs, else: inputs ++ [queued]
  end

  defp update_code_agent(socket, sub_id, "tool_use", %{tool: name}) do
    update(socket, :code_agent_sessions, fn sessions ->
      Map.update(sessions, sub_id, %{}, fn entry ->
        tc = %{name: name, status: "running"}
        %{entry | tool_calls: entry.tool_calls ++ [tc]}
      end)
    end)
  end

  defp update_code_agent(socket, sub_id, "tool_result", %{tool_use_id: _id} = payload) do
    status = if payload[:is_error], do: "error", else: "complete"

    update(socket, :code_agent_sessions, fn sessions ->
      Map.update(sessions, sub_id, %{}, fn entry ->
        # Mark last tool_call as complete
        calls =
          case Enum.reverse(entry.tool_calls) do
            [last | rest] -> Enum.reverse([%{last | status: status} | rest])
            [] -> []
          end

        %{entry | tool_calls: calls}
      end)
    end)
  end

  defp update_code_agent(socket, sub_id, "done", payload) do
    update(socket, :code_agent_sessions, fn sessions ->
      Map.update(sessions, sub_id, %{}, fn entry ->
        %{
          entry
          | status: "complete",
            completion: payload[:content] || payload[:text] || entry.completion
        }
      end)
    end)
  end

  defp update_code_agent(socket, _sub_id, _event, _payload), do: socket
end
