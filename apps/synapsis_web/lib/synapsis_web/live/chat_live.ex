defmodule SynapsisWeb.ChatLive do
  @moduledoc "Global ChatGPT-style chat UI bound to one selected agent per conversation."
  use SynapsisWeb, :live_view
  require Logger

  alias Synapsis.{AgentConfigs, Sessions}

  @max_content_bytes 256_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "heartbeat:notifications")
    end

    {:ok,
     assign(socket,
       page_title: "Chat",
       agents: [],
       selected_agent: nil,
       agent_config: nil,
       sessions: [],
       current_session: nil,
       messages: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       heartbeat_notifications: [],
       session_status: "idle",
       show_sidebar: true
     )}
  end

  @impl true
  def handle_params(%{"session_id" => session_id}, _uri, socket) do
    socket = assign_chat_data(socket)

    if old = socket.assigns.current_session do
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "session:#{old.id}")
    end

    case Sessions.get(session_id) do
      {:ok, session} ->
        if global_session?(session) do
          session = prepare_chat_session(session)
          Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
          agent_name = session.agent || default_agent_name(socket.assigns.agents)

          {:noreply,
           assign(socket,
             selected_agent: agent_name,
             agent_config: Synapsis.Agent.Resolver.resolve(agent_name),
             sessions: load_global_sessions(),
             current_session: session,
             messages: Sessions.get_messages(session.id),
             streaming_text: "",
             streaming_reasoning: "",
             tool_calls: %{},
             permission_requests: [],
             session_status: session.status || "idle"
           )}
        else
          {:noreply,
           socket
           |> put_flash(:error, "Chat only shows global conversations")
           |> push_navigate(to: ~p"/chat")}
        end

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/chat")}
    end
  end

  def handle_params(_params, _uri, socket) do
    if old = socket.assigns.current_session do
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "session:#{old.id}")
    end

    socket = assign_chat_data(socket)
    selected = socket.assigns.selected_agent || default_agent_name(socket.assigns.agents)

    {:noreply,
     assign(socket,
       selected_agent: selected,
       agent_config: selected && Synapsis.Agent.Resolver.resolve(selected),
       current_session: nil,
       messages: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       session_status: "idle"
     )}
  end

  @impl true
  def handle_event("select_agent", %{"agent" => agent_name}, socket) do
    {:noreply,
     assign(socket,
       selected_agent: agent_name,
       agent_config: Synapsis.Agent.Resolver.resolve(agent_name)
     )}
  end

  def handle_event("create_session", params, socket) do
    agent_name =
      params["agent"] || socket.assigns.selected_agent ||
        default_agent_name(socket.assigns.agents)

    agent_config = Synapsis.Agent.Resolver.resolve(agent_name)

    attrs =
      %{agent: agent_name}
      |> maybe_put_present(:provider, agent_config.provider)
      |> maybe_put_present(:model, agent_config.model)

    case Sessions.create("__global__", attrs) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(sessions: [session | socket.assigns.sessions], selected_agent: agent_name)
         |> push_patch(to: ~p"/chat/#{session.id}")}

      {:error, reason} ->
        Logger.warning("chat_session_create_failed", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to create chat")}
    end
  end

  def handle_event("switch_session", %{"id" => session_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{session_id}")}
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    Sessions.delete(session_id)
    sessions = Enum.reject(socket.assigns.sessions, &(&1.id == session_id))

    if socket.assigns.current_session && socket.assigns.current_session.id == session_id do
      {:noreply, socket |> assign(:sessions, sessions) |> push_navigate(to: ~p"/chat")}
    else
      {:noreply, assign(socket, :sessions, sessions)}
    end
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  def handle_event("send_message", %{"content" => content}, socket) do
    content = String.trim(content)

    cond do
      content == "" or is_nil(socket.assigns.current_session) ->
        {:noreply, socket}

      byte_size(content) > @max_content_bytes ->
        {:noreply, put_flash(socket, :error, "Message too large")}

      true ->
        session = socket.assigns.current_session

        case Sessions.send_message(session.id, content) do
          :ok ->
            {:noreply,
             assign(socket,
               messages: Sessions.get_messages(session.id),
               sessions: load_global_sessions(),
               session_status: "streaming"
             )}

          {:error, reason} ->
            Logger.warning("chat_send_message_failed",
              session_id: session.id,
              reason: inspect(reason)
            )

            {:noreply, put_flash(socket, :error, "Failed to send message")}
        end
    end
  end

  def handle_event("cancel_stream", _params, socket) do
    if session = socket.assigns.current_session, do: Sessions.cancel(session.id)
    {:noreply, socket}
  end

  def handle_event("retry", _params, socket) do
    if session = socket.assigns.current_session, do: Sessions.retry(session.id)
    {:noreply, socket}
  end

  def handle_event("approve_tool", %{"tool-use-id" => tool_use_id}, socket) do
    if session = socket.assigns.current_session,
      do: Sessions.approve_tool(session.id, tool_use_id)

    {:noreply, reject_permission(socket, tool_use_id)}
  end

  def handle_event("deny_tool", %{"tool-use-id" => tool_use_id}, socket) do
    if session = socket.assigns.current_session, do: Sessions.deny_tool(session.id, tool_use_id)
    {:noreply, reject_permission(socket, tool_use_id)}
  end

  def handle_event("dismiss_heartbeat", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        {:noreply,
         update(socket, :heartbeat_notifications, &Enum.reject(&1, fn item -> item.id == id end))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({"text_delta", %{text: text}}, socket) do
    {:noreply,
     socket |> update(:streaming_text, &(&1 <> text)) |> push_event("append_text", %{text: text})}
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
        fn tool_call ->
          Map.merge(tool_call, %{status: status, result: payload[:content]})
        end
      )

    {:noreply, assign(socket, :tool_calls, tool_calls)}
  end

  def handle_info({"permission_request", payload}, socket) do
    {:noreply, update(socket, :permission_requests, &[payload | &1])}
  end

  def handle_info({"permission_requests", %{tools: tools}}, socket) when is_list(tools) do
    {:noreply, update(socket, :permission_requests, &(tools ++ &1))}
  end

  def handle_info({"done", _}, socket) do
    messages =
      if session = socket.assigns.current_session, do: Sessions.get_messages(session.id), else: []

    {:noreply,
     assign(socket,
       messages: messages,
       sessions: load_global_sessions(),
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       session_status: "idle"
     )}
  end

  def handle_info({"session_status", %{status: status}}, socket) do
    {:noreply, assign_session_status(socket, status)}
  end

  def handle_info({"error", %{message: msg}}, socket) do
    messages =
      if session = socket.assigns.current_session, do: Sessions.get_messages(session.id), else: []

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> put_flash(:error, msg)
     |> assign_session_status("error")}
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

    {:noreply, update(socket, :heartbeat_notifications, &([notification | &1] |> Enum.take(10)))}
  end

  def handle_info({:session_compacted, _session_id, _metadata}, socket) do
    messages =
      if session = socket.assigns.current_session,
        do: Sessions.get_messages(session.id, limit: 200),
        else: []

    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info({:system_message, %{type: :compaction} = payload}, socket) do
    {:noreply, put_flash(socket, :info, payload.text)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full">
      <.dm_btn variant="ghost" phx-click="toggle_sidebar" class="md:hidden fixed top-16 left-2 z-20">
        <.dm_mdi name={if(@show_sidebar, do: "close", else: "menu")} class="w-5 h-5" />
      </.dm_btn>

      <aside class={[
        "w-72 bg-secondary text-secondary-content border-r border-outline-variant flex flex-col shrink-0 transition-transform",
        "fixed md:relative inset-y-0 left-0 z-10 md:z-auto md:translate-x-0 pt-16 md:pt-0",
        if(@show_sidebar, do: "translate-x-0", else: "-translate-x-full")
      ]}>
        <div class="p-3 border-b border-outline-variant">
          <h1 class="text-sm font-semibold mb-3">Chat</h1>
          <.dm_form for={%{}} phx-submit="create_session" phx-change="select_agent" class="space-y-2">
            <.dm_select
              name="agent"
              label="Agent"
              options={Enum.map(@agents, &{&1.name, &1.label || String.capitalize(&1.name)})}
              value={@selected_agent}
            />
            <.dm_btn type="submit" variant="outline" class="w-full">
              <.dm_mdi name="plus" class="w-4 h-4" /> New Chat
            </.dm_btn>
          </.dm_form>
        </div>

        <nav class="flex-1 overflow-y-auto">
          <.session_list_item
            :for={session <- @sessions}
            session={session}
            active={@current_session != nil && session.id == @current_session.id}
          />
          <.empty_state
            :if={@sessions == []}
            icon="chat-outline"
            title="No chats"
            description="Start a chat with an agent."
            class="py-8"
          />
        </nav>
      </aside>

      <main class="flex-1 min-w-0 flex flex-col">
        <%= if @current_session do %>
          <div class="flex items-center justify-between border-b border-outline-variant px-4 py-2 bg-surface">
            <div class="flex items-center gap-3 min-w-0">
              <.dm_mdi
                name={@agent_config.icon || "robot-outline"}
                class="w-5 h-5 text-primary shrink-0"
              />
              <div class="min-w-0">
                <h2 class="font-medium text-sm truncate">
                  {@current_session.title || "Session #{String.slice(@current_session.id, 0..7)}"}
                </h2>
                <div class="text-xs text-on-surface-variant">
                  {@agent_config.label || String.capitalize(@selected_agent || "agent")}
                </div>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <.dm_btn :if={@session_status == "error"} variant="ghost" size="xs" phx-click="retry">
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

          <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto p-4 space-y-3">
            <.message_parts :for={msg <- @messages} message={msg} />
            <.reasoning_block
              :if={@streaming_reasoning != ""}
              content={@streaming_reasoning}
              collapsed={false}
            />

            <div :for={{_id, tool_call} <- @tool_calls} :if={tool_call.status == "running"}>
              <.tool_call_display name={tool_call.name} status={tool_call.status}>
                <:params>
                  <pre class="max-h-32 overflow-y-auto">{Jason.encode!(tool_call.input || %{}, pretty: true)}</pre>
                </:params>
              </.tool_call_display>
            </div>

            <.permission_card :for={request <- @permission_requests} {request} />

            <div :for={notification <- @heartbeat_notifications} class="relative">
              <.heartbeat_card name={notification.name} timestamp={notification.timestamp}>
                <p class="whitespace-pre-wrap leading-relaxed text-sm">
                  {String.slice(notification.result || "", 0, 500)}
                </p>
              </.heartbeat_card>
              <.dm_btn
                variant="ghost"
                size="xs"
                phx-click="dismiss_heartbeat"
                phx-value-id={notification.id}
                class="absolute top-1 right-1 text-on-surface-variant/50 hover:text-on-surface-variant"
              >
                <.dm_mdi name="close" class="w-3.5 h-3.5" />
              </.dm_btn>
            </div>

            <.chat_bubble
              :if={@streaming_text != "" || @session_status == "streaming"}
              role="assistant"
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

          <div class="border-t border-outline-variant p-3 bg-surface">
            <el-dm-markdown-input
              id="message-input"
              name="content"
              value=""
              phx-hook="MarkdownSubmit"
              placeholder="Send a message... (Ctrl+Enter to send)"
              disabled={@session_status not in ~w(idle error)}
              theme="auto"
              class={[
                "w-full min-h-[80px] max-h-[200px]",
                if(@session_status not in ~w(idle error), do: "opacity-50 cursor-not-allowed")
              ]}
            >
              <div slot="bottom-end">
                <.dm_btn
                  id="send-btn"
                  variant="primary"
                  size="sm"
                  disabled={@session_status not in ~w(idle error)}
                  phx-hook="SendButton"
                >
                  <.dm_mdi name="send" class="w-4 h-4" />
                  <span>Send</span>
                </.dm_btn>
              </div>
            </el-dm-markdown-input>
          </div>
        <% else %>
          <div class="flex-1 flex items-center justify-center">
            <.empty_state
              icon="chat-outline"
              title="New Chat"
              description="Choose an agent and start a conversation."
            />
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  defp assign_chat_data(socket) do
    agents = load_agents()

    assign(socket,
      agents: agents,
      sessions: load_global_sessions()
    )
  end

  defp prepare_chat_session(%{status: status} = session)
       when status in ~w(streaming tool_executing) do
    with :ok <- Sessions.ensure_running(session.id),
         {:ok, refreshed} <- Sessions.get(session.id),
         {:ok, recovered} <- Sessions.recover_stale_transient_status(refreshed) do
      if recovered.status in ~w(idle error), do: prepare_chat_session(recovered), else: recovered
    else
      _ -> session
    end
  end

  defp prepare_chat_session(%{status: status} = session) when status in ~w(idle error) do
    case Sessions.recover_unsupported_provider_model(session) do
      {:ok, recovered} -> recovered
      _ -> session
    end
  end

  defp prepare_chat_session(session), do: session

  defp maybe_put_present(attrs, _key, value) when value in [nil, ""], do: attrs
  defp maybe_put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp load_agents do
    case AgentConfigs.list_enabled() do
      [] -> Enum.map(AgentConfigs.default_attrs(), &struct(AgentConfigCompat, &1))
      agents -> agents
    end
  end

  defp load_global_sessions do
    Sessions.recent(limit: 100)
    |> Enum.filter(&global_session?/1)
  end

  defp global_session?(session), do: session.project && session.project.path == "__global__"

  defp default_agent_name([agent | _]), do: agent.name
  defp default_agent_name([]), do: "main"

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
    socket
    |> maybe_refresh_current_session()
    |> clear_transient_generation()
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

  defp clear_transient_generation(socket) do
    assign(socket,
      streaming_text: "",
      streaming_reasoning: "",
      tool_calls: %{},
      permission_requests: []
    )
  end

  defp reject_permission(socket, tool_use_id) do
    update(
      socket,
      :permission_requests,
      &Enum.reject(&1, fn request -> request.tool_use_id == tool_use_id end)
    )
  end

  defmodule AgentConfigCompat do
    defstruct [:name, :label, :icon, :description, :provider, :model]
  end
end
