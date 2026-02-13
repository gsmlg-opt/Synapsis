defmodule SynapsisWeb.SessionLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => session_id, "project_id" => project_id}, _session, socket) do
    case {Synapsis.Projects.get(project_id), Synapsis.Sessions.get(session_id)} do
      {{:ok, project}, {:ok, session}} ->
        sessions = Synapsis.Sessions.list_by_project(project.id)

        {:ok,
         assign(socket,
           project: project,
           session: session,
           sessions: sessions,
           agent_mode: session.agent || "build",
           provider_label: "#{session.provider}/#{session.model}",
           page_title: session.title || "Session"
         )}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/projects/#{project_id}")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_agent", %{"mode" => mode}, socket) when mode in ["build", "plan"] do
    {:noreply, assign(socket, agent_mode: mode)}
  end

  def handle_event("switch_session", %{"id" => id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/projects/#{socket.assigns.project.id}/sessions/#{id}"
     )}
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    case Synapsis.Sessions.delete(id) do
      {:ok, _} ->
        sessions = Enum.reject(socket.assigns.sessions, &(&1.id == id))

        if id == socket.assigns.session.id do
          {:noreply,
           socket
           |> assign(sessions: sessions)
           |> push_navigate(to: ~p"/projects/#{socket.assigns.project.id}")}
        else
          {:noreply, assign(socket, sessions: sessions)}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete session")}
    end
  end

  def handle_event("create_session", _params, socket) do
    case Synapsis.Sessions.create(socket.assigns.project.path) do
      {:ok, session} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/projects/#{socket.assigns.project.id}/sessions/#{session.id}"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-gray-950 text-gray-100">
      <%!-- Sidebar --%>
      <aside class="w-64 bg-gray-900 border-r border-gray-800 flex flex-col">
        <div class="p-4 border-b border-gray-800">
          <.link
            navigate={~p"/projects/#{@project.id}"}
            class="text-lg font-semibold hover:text-blue-400"
          >
            {@project.slug}
          </.link>
          <button
            phx-click="create_session"
            class="mt-2 w-full px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + New Session
          </button>
        </div>
        <div class="flex-1 overflow-y-auto">
          <div
            :for={s <- @sessions}
            class={[
              "px-4 py-3 cursor-pointer border-b border-gray-800 hover:bg-gray-800 flex justify-between items-center",
              s.id == @session.id && "bg-gray-800"
            ]}
          >
            <.link
              navigate={~p"/projects/#{@project.id}/sessions/#{s.id}"}
              class="min-w-0 flex-1"
            >
              <div class="text-sm truncate">
                {s.title || "Session #{String.slice(s.id, 0, 8)}"}
              </div>
              <div class="text-xs text-gray-500 mt-0.5">
                {s.provider}/{s.model}
              </div>
            </.link>
            <button
              phx-click="delete_session"
              phx-value-id={s.id}
              class="ml-2 text-gray-600 hover:text-red-400 text-xs"
            >
              &#10005;
            </button>
          </div>
        </div>
      </aside>

      <%!-- Main content --%>
      <main class="flex-1 flex flex-col">
        <%!-- Session header --%>
        <div class="px-4 py-3 border-b border-gray-800 flex items-center justify-between">
          <div>
            <h2 class="font-semibold">{@session.title || "Session"}</h2>
            <div class="text-xs text-gray-500">{@provider_label}</div>
          </div>
          <div class="flex gap-2">
            <button
              :for={mode <- ["build", "plan"]}
              phx-click="switch_agent"
              phx-value-mode={mode}
              class={[
                "px-3 py-1 text-sm rounded",
                if(@agent_mode == mode,
                  do: "bg-blue-600 text-white",
                  else: "bg-gray-800 text-gray-400 hover:text-gray-200"
                )
              ]}
            >
              {mode}
            </button>
          </div>
        </div>

        <%!-- React ChatApp --%>
        <div
          id={"chat-#{@session.id}"}
          phx-hook="ChatApp"
          phx-update="ignore"
          data-session-id={@session.id}
          data-agent-mode={@agent_mode}
          class="flex-1 overflow-hidden"
        >
        </div>
      </main>
    </div>
    """
  end
end
