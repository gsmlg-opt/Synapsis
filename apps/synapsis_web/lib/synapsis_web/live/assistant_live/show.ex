defmodule SynapsisWeb.AssistantLive.Show do
  @moduledoc "Chat interface for a named assistant with session sidebar and PubSub streaming."
  use SynapsisWeb, :live_view

  alias Synapsis.Sessions

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    agent_config = Synapsis.Agent.Resolver.resolve(name)
    provider_configured? = not is_nil(agent_config.provider)

    {:ok,
     assign(socket,
       page_title: "#{String.capitalize(name)} Assistant",
       assistant_name: name,
       agent_config: agent_config,
       provider_configured: provider_configured?,
       sessions: [],
       current_session: nil,
       messages: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       session_status: "idle",
       show_new_session: false,
       show_sidebar: true,
       current_mode: name
     )}
  end

  @impl true
  def handle_params(%{"session_id" => session_id} = params, _uri, socket) do
    name = params["name"] || socket.assigns.assistant_name
    sessions = load_sessions(name)

    # Unsubscribe from previous session
    if old = socket.assigns.current_session do
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "session:#{old.id}")
    end

    case Sessions.get(session_id) do
      {:ok, session} ->
        Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
        messages = Sessions.get_messages(session.id)

        {:noreply,
         assign(socket,
           assistant_name: name,
           sessions: sessions,
           current_session: session,
           messages: messages,
           streaming_text: "",
           streaming_reasoning: "",
           tool_calls: %{},
           permission_requests: [],
           session_status: session.status || "idle",
           current_mode: session.agent || name
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/assistant/#{name}/sessions")}
    end
  end

  def handle_params(%{"name" => name}, _uri, socket) do
    sessions = load_sessions(name)

    if old = socket.assigns.current_session do
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "session:#{old.id}")
    end

    {:noreply,
     assign(socket,
       assistant_name: name,
       sessions: sessions,
       current_session: nil,
       messages: [],
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       session_status: "idle"
     )}
  end

  # --- Events ---

  @impl true
  def handle_event("send_message", %{"content" => content}, socket) do
    content = String.trim(content)

    if content == "" or is_nil(socket.assigns.current_session) do
      {:noreply, socket}
    else
      Sessions.send_message(socket.assigns.current_session.id, content)
      {:noreply, socket}
    end
  end

  def handle_event("toggle_new_session", _params, socket) do
    {:noreply, assign(socket, :show_new_session, !socket.assigns.show_new_session)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  def handle_event("create_session", _params, socket) do
    name = socket.assigns.assistant_name
    # Re-resolve to pick up any config changes saved from the setting page
    agent_config = Synapsis.Agent.Resolver.resolve(name)
    provider = agent_config.provider || "anthropic"
    model = agent_config.model || Synapsis.Providers.default_model(provider)

    case Sessions.create("__global__", %{provider: provider, model: model, agent: name}) do
      {:ok, session} ->
        sessions = [session | socket.assigns.sessions]

        {:noreply,
         socket
         |> assign(sessions: sessions, show_new_session: false)
         |> push_patch(to: ~p"/assistant/#{name}/sessions/#{session.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create session: #{inspect(reason)}")}
    end
  end

  def handle_event("switch_session", %{"id" => session_id}, socket) do
    name = socket.assigns.assistant_name
    {:noreply, push_patch(socket, to: ~p"/assistant/#{name}/sessions/#{session_id}")}
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    name = socket.assigns.assistant_name
    Sessions.delete(session_id)
    sessions = Enum.reject(socket.assigns.sessions, &(&1.id == session_id))

    if socket.assigns.current_session && socket.assigns.current_session.id == session_id do
      {:noreply,
       socket
       |> assign(:sessions, sessions)
       |> push_navigate(to: ~p"/assistant/#{name}/sessions")}
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

  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    if session = socket.assigns.current_session do
      Sessions.switch_mode(session.id, mode)
    end

    {:noreply, assign(socket, :current_mode, mode)}
  end

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

  def handle_info({"done", _}, socket) do
    name = socket.assigns.assistant_name

    messages =
      if session = socket.assigns.current_session do
        Sessions.get_messages(session.id)
      else
        []
      end

    sessions = load_sessions(name)

    {:noreply,
     assign(socket,
       messages: messages,
       sessions: sessions,
       streaming_text: "",
       streaming_reasoning: "",
       tool_calls: %{},
       permission_requests: [],
       session_status: "idle"
     )}
  end

  def handle_info({"session_status", %{status: status}}, socket) do
    {:noreply, assign(socket, :session_status, status)}
  end

  def handle_info({"error", %{message: msg}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, msg)
     |> assign(:session_status, "error")}
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
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full">
      <%!-- Mobile sidebar toggle --%>
      <button
        phx-click="toggle_sidebar"
        class="md:hidden fixed top-16 left-2 z-20 p-1.5 rounded-lg bg-base-200 border border-base-300"
      >
        <.dm_mdi name={if(@show_sidebar, do: "close", else: "menu")} class="w-5 h-5" />
      </button>

      <%!-- Sidebar --%>
      <aside class={[
        "w-64 bg-base-200 border-r border-base-300 flex flex-col shrink-0 transition-transform",
        "fixed md:relative inset-y-0 left-0 z-10 md:z-auto md:translate-x-0 pt-16 md:pt-0",
        if(@show_sidebar, do: "translate-x-0", else: "-translate-x-full")
      ]}>
        <%!-- Assistant header --%>
        <div class="p-3 border-b border-base-300">
          <div class="flex items-center justify-between mb-2">
            <.dm_link
              navigate={~p"/assistant"}
              class="text-xs text-base-content/50 hover:text-base-content"
            >
              <.dm_mdi name="chevron-left" class="w-3.5 h-3.5 inline" /> Assistants
            </.dm_link>
            <.dm_link
              navigate={~p"/assistant/#{@assistant_name}/setting"}
              class="text-xs text-base-content/50 hover:text-base-content"
            >
              <.dm_mdi name="cog-outline" class="w-3.5 h-3.5" />
            </.dm_link>
          </div>
          <%= if @provider_configured do %>
            <.dm_btn variant="primary" class="w-full" phx-click="toggle_new_session">
              <.dm_mdi name="plus" class="w-4 h-4" /> New Session
            </.dm_btn>
          <% else %>
            <.dm_tooltip content="Set a provider in assistant settings first" position="bottom" color="warning">
              <.dm_btn variant="primary" class="w-full opacity-50 cursor-not-allowed" disabled>
                <.dm_mdi name="plus" class="w-4 h-4" /> New Session
              </.dm_btn>
            </.dm_tooltip>
          <% end %>
        </div>

        <%!-- New session confirm --%>
        <div :if={@show_new_session && @provider_configured} class="p-3 border-b border-base-300 bg-base-100">
          <div class="text-xs text-base-content/50 mb-2">
            {@agent_config.provider} / {@agent_config.model || Synapsis.Providers.default_model(@agent_config.provider)}
          </div>
          <.dm_btn variant="primary" size="sm" class="w-full" phx-click="create_session">
            Create Session
          </.dm_btn>
        </div>

        <%!-- Session list --%>
        <nav class="flex-1 overflow-y-auto">
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
          <div class="flex items-center justify-between border-b border-base-300 px-4 py-2 bg-base-100">
            <div class="flex items-center gap-3 min-w-0">
              <.dm_mdi name="chat-outline" class="w-5 h-5 text-base-content/50 shrink-0" />
              <div class="min-w-0">
                <h2 class="font-medium text-sm truncate">
                  {@current_session.title || "Session #{String.slice(@current_session.id, 0..7)}"}
                </h2>
                <div class="text-xs text-base-content/40">
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
          <div
            id="messages"
            phx-hook="ScrollBottom"
            class="flex-1 overflow-y-auto p-4 space-y-3"
          >
            <.message_parts :for={msg <- @messages} message={msg} />

            <.reasoning_block
              :if={@streaming_reasoning != ""}
              content={@streaming_reasoning}
              collapsed={false}
            />

            <div :for={{_id, tc} <- @tool_calls} :if={tc.status == "running"}>
              <.tool_call_display name={tc.name} status={tc.status}>
                <:params>
                  <pre class="max-h-32 overflow-y-auto">{Jason.encode!(tc.input || %{}, pretty: true)}</pre>
                </:params>
              </.tool_call_display>
            </div>

            <.permission_card :for={req <- @permission_requests} {req} />

            <.chat_bubble
              :if={@streaming_text != "" || @session_status == "streaming"}
              role="assistant"
            >
              <p
                id="streaming-output"
                phx-hook="StreamingText"
                class="whitespace-pre-wrap leading-relaxed"
              >
                {@streaming_text}
              </p>
            </.chat_bubble>

            <.streaming_indicator :if={@session_status == "streaming" && @streaming_text == ""} />
          </div>

          <%!-- Input area --%>
          <div class="border-t border-base-300 p-3 bg-base-100">
            <div class="flex gap-2 items-end">
              <textarea
                id="message-input"
                phx-hook="TextareaSubmit"
                placeholder="Send a message... (Enter to send, Shift+Enter for newline)"
                disabled={@session_status not in ~w(idle error)}
                class={[
                  "flex-1 bg-base-200 border border-base-300 rounded-lg px-3 py-2 text-sm resize-none",
                  "focus:outline-none focus:border-primary/50",
                  if(@session_status not in ~w(idle error), do: "opacity-50 cursor-not-allowed")
                ]}
                rows="2"
              />
            </div>
          </div>
        <% else %>
          <%!-- Empty state --%>
          <div class="flex-1 flex items-center justify-center">
            <.empty_state
              icon="robot-outline"
              title={"#{String.capitalize(@assistant_name)} Assistant"}
              description={if @provider_configured, do: "Create or select a session to start chatting", else: "Configure a provider in settings to start chatting"}
            >
              <:action>
                <%= if @provider_configured do %>
                  <.dm_btn variant="primary" phx-click="toggle_new_session">
                    <.dm_mdi name="plus" class="w-4 h-4" /> New Session
                  </.dm_btn>
                <% else %>
                  <.dm_link navigate={~p"/assistant/#{@assistant_name}/setting"}>
                    <.dm_btn variant="primary">
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
    Sessions.recent(limit: 50)
    |> Enum.filter(&(&1.agent == agent_name))
  end

end
