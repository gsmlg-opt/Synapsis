defmodule SynapsisWeb.AgentLive.Sessions do
  @moduledoc "Chat interface for a named agent with session sidebar and PubSub streaming."
  use SynapsisWeb, :live_view
  require Logger

  alias Synapsis.Sessions

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
       provider_configured: provider_configured?,
       sessions: [],
       current_session: nil,
       messages: [],
       queued_inputs: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       heartbeat_notifications: [],
       code_agent_sessions: %{},
       session_status: "idle",
       show_new_session: false,
       show_sidebar: true,
       current_mode: agent_id
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
        {status, in_flight} = live_session_state(session)

        {:noreply,
         assign(socket,
           agent_id: agent_id,
           sessions: sessions,
           current_session: session,
           messages: messages,
           queued_inputs: [],
           streaming_text: in_flight,
           streaming_reasoning: "",
           tool_calls: %{},
           permission_requests: [],
           code_agent_sessions: %{},
           session_status: status,
           current_mode: session.agent || agent_id
         )}

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
           queued_inputs: []
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
       session_status: "idle"
     )}
  end

  # ADR-006 B2: resolve {status, in_flight_text} from the live read authority
  # (the running session process), falling back to Concord's durable snapshot
  # and finally the DB status. Returns UI status vocabulary ("idle"/"streaming").
  defp live_session_state(session) do
    case Synapsis.Session.Read.live_snapshot(session.id) do
      {:live, %{status: status, in_flight_text: text}} ->
        {live_status_string(status), text || ""}

      {:durable, %{meta: %{status: status}}} when is_binary(status) ->
        {status, ""}

      _ ->
        {session.status || "idle", ""}
    end
  end

  defp live_status_string(:running), do: "streaming"
  defp live_status_string(:waiting), do: "idle"
  defp live_status_string(other), do: to_string(other)

  # --- Events ---

  @impl true
  @max_content_bytes 256_000

  def handle_event("send_message", %{"value" => content}, socket) do
    send_message(content, socket)
  end

  def handle_event("send_message", %{"content" => content}, socket) do
    send_message(content, socket)
  end

  def handle_event("steer_message", %{"value" => content}, socket) do
    steer_message(content, socket)
  end

  def handle_event("steer_message", %{"content" => content}, socket) do
    steer_message(content, socket)
  end

  def handle_event("toggle_new_session", _params, socket) do
    {:noreply, assign(socket, :show_new_session, !socket.assigns.show_new_session)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  def handle_event("create_session", _params, socket) do
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
         |> assign(sessions: sessions, show_new_session: false)
         |> push_patch(to: ~p"/agent/agents/#{agent_id}/sessions/#{session.id}")}

      {:error, reason} ->
        Logger.warning("session_create_failed", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("switch_session", %{"id" => session_id}, socket) do
    agent_id = socket.assigns.agent_id
    {:noreply, push_patch(socket, to: ~p"/agent/agents/#{agent_id}/sessions/#{session_id}")}
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    agent_id = socket.assigns.agent_id
    Sessions.delete(session_id)
    sessions = Enum.reject(socket.assigns.sessions, &(&1.id == session_id))

    if socket.assigns.current_session && socket.assigns.current_session.id == session_id do
      {:noreply,
       socket
       |> assign(:sessions, sessions)
       |> push_navigate(to: ~p"/agent/agents/#{agent_id}/sessions")}
    else
      {:noreply, assign(socket, :sessions, sessions)}
    end
  end

  def handle_event("cancel_stream", _params, socket) do
    if session = socket.assigns.current_session do
      Sessions.cancel(session.id)
    end

    {:noreply, socket}
  end

  def handle_event("retry", _params, socket) do
    if session = socket.assigns.current_session do
      Sessions.retry(session.id)
    end

    {:noreply, socket}
  end

  def handle_event("regenerate", %{"id" => message_id}, socket) do
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

  def handle_event("approve_tool", %{"tool-use-id" => tool_use_id}, socket) do
    if session = socket.assigns.current_session do
      Sessions.approve_tool(session.id, tool_use_id)
    end

    requests = Enum.reject(socket.assigns.permission_requests, &(&1.tool_use_id == tool_use_id))
    {:noreply, assign(socket, :permission_requests, requests)}
  end

  def handle_event("deny_tool", %{"tool-use-id" => tool_use_id}, socket) do
    if session = socket.assigns.current_session do
      Sessions.deny_tool(session.id, tool_use_id)
    end

    requests = Enum.reject(socket.assigns.permission_requests, &(&1.tool_use_id == tool_use_id))
    {:noreply, assign(socket, :permission_requests, requests)}
  end

  def handle_event("dismiss_heartbeat", %{"id" => id_str}, socket) do
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

  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    if session = socket.assigns.current_session do
      Sessions.switch_mode(session.id, mode)
    end

    {:noreply, assign(socket, :current_mode, mode)}
  end

  defp send_message(content, socket) when is_binary(content) do
    content = String.trim(content)

    cond do
      content == "" or is_nil(socket.assigns.current_session) ->
        {:noreply, socket}

      byte_size(content) > @max_content_bytes ->
        {:noreply, put_flash(socket, :error, "Message too large")}

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
              parts: [%Synapsis.Part.Text{content: content}],
              inserted_at: DateTime.utc_now()
            }

            socket
            |> update(:messages, &(&1 ++ [optimistic_msg]))
            |> assign(:session_status, "streaming")
            |> assign(:tool_calls, %{})
          end

        case Sessions.send_message(session_id, content) do
          :ok ->
            if running? do
              queued = %{
                id: "local-#{Ecto.UUID.generate()}",
                kind: "prompt",
                content: content,
                local?: true
              }

              {:noreply, update(socket, :queued_inputs, &append_unique_input(&1, queued))}
            else
              # Reload from DB to get the real persisted message with correct ID/timestamps
              {:noreply, assign(socket, :messages, Sessions.get_messages(session_id))}
            end

          {:error, reason} ->
            Logger.warning("session_send_failed", session_id: session_id, reason: inspect(reason))

            {:noreply,
             socket
             |> assign(:messages, Sessions.get_messages(session_id))
             |> assign(:session_status, "error")
             |> put_flash(:error, "Failed to send message")}
        end
    end
  end

  defp send_message(_content, socket), do: {:noreply, socket}

  defp steer_message(content, socket) when is_binary(content) do
    content = String.trim(content)

    cond do
      content == "" or is_nil(socket.assigns.current_session) ->
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
  def handle_info({"text_delta", %{text: text}}, socket) do
    socket =
      socket
      |> update(:streaming_text, &(&1 <> text))
      |> push_event("append_text", %{text: text})

    {:noreply, socket}
  end

  def handle_info({"reasoning", %{text: text}}, socket) do
    {:noreply, update(socket, :streaming_reasoning, &(&1 <> text))}
  end

  def handle_info({"tool_use", %{tool: name, tool_use_id: id}}, socket) do
    tool_calls =
      Map.put(socket.assigns.tool_calls, id, %{
        name: name,
        status: "running",
        input: %{},
        result: nil
      })

    {:noreply, assign(socket, :tool_calls, tool_calls)}
  end

  def handle_info({"tool_result", %{tool_use_id: id} = payload}, socket) do
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

  def handle_info({"permission_request", payload}, socket) do
    {:noreply, update(socket, :permission_requests, &[payload | &1])}
  end

  def handle_info({"permission_requests", %{tools: tools}}, socket) when is_list(tools) do
    {:noreply, update(socket, :permission_requests, &(tools ++ &1))}
  end

  def handle_info({"input_queued", %{id: id, kind: "prompt", content: content}}, socket) do
    queued = %{id: id, kind: "prompt", content: content}
    {:noreply, update(socket, :queued_inputs, &append_unique_input(&1, queued))}
  end

  def handle_info({"input_queued", %{kind: "steer"}}, socket) do
    {:noreply, socket}
  end

  def handle_info({"input_started", %{id: id}}, socket) do
    {:noreply, update(socket, :queued_inputs, &Enum.reject(&1, fn input -> input.id == id end))}
  end

  def handle_info({"done", _}, socket) do
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
       queued_inputs: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: error_tool_calls,
       permission_requests: [],
       session_status: "idle"
     )}
  end

  def handle_info({"session_status", %{status: status}}, socket) do
    {:noreply, assign_session_status(socket, status)}
  end

  def handle_info({"error", %{message: msg}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, msg)
     |> assign_session_status("error")}
  end

  def handle_info({"agent_switched", %{agent: agent}}, socket) do
    {:noreply, assign(socket, :current_mode, agent)}
  end

  def handle_info({"model_switched", _payload}, socket) do
    if session = socket.assigns.current_session do
      case Sessions.get(session.id) do
        {:ok, updated} -> {:noreply, assign(socket, :current_session, updated)}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({"mode_switched", %{agent: agent}}, socket) do
    {:noreply, assign(socket, :current_mode, agent)}
  end

  def handle_info({"auditing", _payload}, socket), do: {:noreply, socket}

  def handle_info({:session_compacted, _session_id, _metadata}, socket) do
    messages =
      if session = socket.assigns.current_session do
        Sessions.get_messages(session.id, limit: 200)
      else
        []
      end

    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info({:system_message, %{type: :compaction} = payload}, socket) do
    {:noreply, put_flash(socket, :info, payload.text)}
  end

  def handle_info(
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

  def handle_info(
        {"code_agent_spawned", %{sub_session_id: sub_id, prompt: prompt}},
        socket
      ) do
    entry = %{prompt: prompt, status: "running", tool_calls: [], completion: nil}
    {:noreply, update(socket, :code_agent_sessions, &Map.put(&1, sub_id, entry))}
  end

  def handle_info(
        {"code_agent_event", %{sub_session_id: sub_id, event: event, payload: payload}},
        socket
      ) do
    {:noreply, update_code_agent(socket, sub_id, event, payload)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
                  {@agent_config.provider}/{@agent_config.model ||
                    Synapsis.Providers.default_model(@agent_config.provider)}
                <% else %>
                  Provider not configured
                <% end %>
              </p>
            </div>
          </div>

          <%= if @provider_configured do %>
            <.dm_btn variant="primary" class="w-full mt-3" phx-click="toggle_new_session">
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

        <%!-- New session confirm --%>
        <div
          :if={@show_new_session && @provider_configured}
          class="m-3 rounded-md border border-outline-variant bg-surface-container-high p-3"
        >
          <div class="text-xs text-on-surface-variant mb-2">
            {@agent_config.provider} / {@agent_config.model ||
              Synapsis.Providers.default_model(@agent_config.provider)}
          </div>
          <.dm_btn variant="outline" size="sm" class="w-full" phx-click="create_session">
            Create Session
          </.dm_btn>
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
                  <span class="text-primary/70">
                    {@agent_config.label || String.capitalize(@agent_id)}
                  </span>
                  <span class="mx-1">&middot;</span>
                  {@current_session.provider}/{@current_session.model}
                </div>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <.dm_btn
                :if={@session_status == "error"}
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

          <%!-- Message list --%>
          <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto p-5 space-y-4">
            <.message_parts
              :for={msg <- @messages}
              message={msg}
              assistant_label={agent_display_name(@agent_config, @agent_id)}
              assistant_avatar={agent_avatar(@agent_config)}
              can_regenerate={@session_status != "streaming"}
            />

            <.queued_prompt
              :for={input <- @queued_inputs}
              id={"queued-input-#{input.id}"}
              content={input.content}
            />

            <.reasoning_block
              :if={@streaming_reasoning != ""}
              content={@streaming_reasoning}
              collapsed={false}
            />

            <div :for={{_id, tc} <- @tool_calls}>
              <.tool_call_display name={tc[:name] || "tool"} status={tc[:status] || "pending"}>
                <:params>
                  <pre class="max-h-32 overflow-y-auto">{Jason.encode!(tc[:input] || %{}, pretty: true)}</pre>
                </:params>
                <:result :if={tc[:result] not in [nil, ""]}>
                  <pre class={[
                    "max-h-48 overflow-y-auto whitespace-pre-wrap",
                    if(tc[:status] == "error", do: "text-error", else: nil)
                  ]}>{tc[:result]}</pre>
                </:result>
              </.tool_call_display>
            </div>

            <.permission_card :for={req <- @permission_requests} {req} />

            <%!-- Heartbeat notification cards --%>
            <div :for={notif <- @heartbeat_notifications} class="relative">
              <.heartbeat_card name={notif.name} timestamp={notif.timestamp}>
                <p class="whitespace-pre-wrap leading-relaxed text-sm">
                  {String.slice(notif.result || "", 0, 500)}
                </p>
              </.heartbeat_card>
              <.dm_btn
                variant="ghost"
                size="xs"
                phx-click="dismiss_heartbeat"
                phx-value-id={notif.id}
                class="absolute top-1 right-1 text-on-surface-variant/50 hover:text-on-surface-variant"
              >
                <.dm_mdi name="close" class="w-3.5 h-3.5" />
              </.dm_btn>
            </div>

            <%!-- Embedded Code Agent panels --%>
            <.code_agent_panel
              :for={{_sub_id, agent} <- @code_agent_sessions}
              prompt={agent.prompt}
              status={agent.status}
              tool_calls={agent.tool_calls}
              completion={agent.completion}
            />

            <.chat_bubble
              :if={@streaming_text != "" || @session_status == "streaming"}
              role="assistant"
              label={agent_display_name(@agent_config, @agent_id)}
              avatar={agent_avatar(@agent_config)}
              status="streaming"
            >
              <.dm_markdown
                id="streaming-output"
                phx-hook="StreamingText"
                content={@streaming_text}
                theme="auto"
              />
            </.chat_bubble>

            <.streaming_indicator :if={@session_status == "streaming" && @streaming_text == ""} />
          </div>

          <%!-- Agent working indicator --%>
          <.agent_working_indicator
            :if={@session_status in ~w(streaming tool_executing)}
            status={@session_status}
          />

          <%!-- Input area --%>
          <div class="border-t border-outline-variant bg-surface-container-low p-3">
            <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#41 --%>
            <.dm_chat_input
              id="message-input"
              name="content"
              value=""
              placeholder="Send a message... (Ctrl/Cmd+Enter)"
              disabled={chat_input_disabled?(@session_status)}
              send_label={if running_session_status?(@session_status), do: "Queue", else: "Send"}
              clear_on_send
              duskmoon-send-send="send_message"
              duskmoon-send-quick-action="steer_message"
              class={[
                "synapsis-chat-input w-full",
                if(chat_input_disabled?(@session_status), do: "opacity-50 cursor-not-allowed")
              ]}
            />
          </div>

          <%!-- Status bar --%>
          <.session_status_bar
            current_mode={@current_mode}
            session_status={@session_status}
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
                  <.dm_btn variant="secondary" phx-click="toggle_new_session">
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
    </div>
    """
  end

  # --- Helpers ---

  defp load_sessions(agent_name) do
    {:ok, sessions} = Sessions.list(agent_name, limit: 50)
    sessions
  end

  defp agent_display_name(agent_config, agent_id) do
    base =
      case agent_config do
        %{label: label} when label not in [nil, ""] -> label
        _ -> String.capitalize(agent_id)
      end

    if String.ends_with?(base, "Agent"), do: base, else: "#{base} Agent"
  end

  defp agent_avatar(%{icon: icon}) when is_binary(icon) do
    if String.contains?(icon, "-") or length(String.graphemes(icon)) > 3, do: nil, else: icon
  end

  defp agent_avatar(_agent_config), do: nil

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
    |> assign(:queued_inputs, [])
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

  defp running_session_status?(status), do: status in @running_statuses

  defp chat_input_disabled?(status),
    do: status not in ~w(idle error streaming tool_executing)

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
      queued_inputs: []
    )
  end

  defp append_unique_input(inputs, queued) do
    cond do
      Enum.any?(inputs, &(&1.id == queued.id)) ->
        inputs

      index = Enum.find_index(inputs, &same_queued_content?(&1, queued)) ->
        existing = Enum.at(inputs, index)

        if Map.get(existing, :local?) && !Map.get(queued, :local?) do
          List.replace_at(inputs, index, queued)
        else
          inputs
        end

      true ->
        inputs ++ [queued]
    end
  end

  defp same_queued_content?(%{kind: kind, content: content}, %{kind: kind, content: content}),
    do: true

  defp same_queued_content?(_existing, _queued), do: false

  defp queued_prompt(assigns) do
    ~H"""
    <div
      id={@id}
      data-queued-input={@id}
      class="ml-auto flex max-w-[min(42rem,85%)] flex-col items-end gap-1 rounded-md border border-primary/30 bg-primary-container/30 px-3 py-2 text-on-surface"
    >
      <div class="flex items-center gap-1 text-[0.7rem] font-medium uppercase text-primary">
        <.dm_mdi name="clock-outline" class="h-3.5 w-3.5" />
        <span>Queued</span>
      </div>
      <p class="max-w-full whitespace-pre-wrap break-words text-sm leading-relaxed">
        {@content}
      </p>
    </div>
    """
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

  defp update_code_agent(socket, sub_id, "done", _payload) do
    update(socket, :code_agent_sessions, fn sessions ->
      Map.update(sessions, sub_id, %{}, fn entry ->
        %{entry | status: "complete"}
      end)
    end)
  end

  defp update_code_agent(socket, _sub_id, _event, _payload), do: socket
end
