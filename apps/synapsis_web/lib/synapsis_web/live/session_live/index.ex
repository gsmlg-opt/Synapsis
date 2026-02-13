defmodule SynapsisWeb.SessionLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    case Synapsis.Projects.get(project_id) do
      {:ok, project} ->
        sessions = Synapsis.Sessions.list_by_project(project.id)
        {:ok, assign(socket, project: project, sessions: sessions, page_title: "Sessions")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Project not found")
         |> push_navigate(to: ~p"/projects")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/projects"} class="hover:text-gray-300">Projects</.link>
          <span>/</span>
          <.link navigate={~p"/projects/#{@project.id}"} class="hover:text-gray-300">
            {@project.slug}
          </.link>
          <span>/</span>
          <span class="text-gray-300">Sessions</span>
        </div>

        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">Sessions</h1>
          <button
            phx-click="create_session"
            class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + New Session
          </button>
        </div>

        <.flash_group flash={@flash} />

        <div class="space-y-2">
          <div
            :for={session <- @sessions}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800 hover:border-gray-700"
          >
            <.link navigate={~p"/projects/#{@project.id}/sessions/#{session.id}"}>
              <div class="font-medium">
                {session.title || "Session #{String.slice(session.id, 0, 8)}"}
              </div>
              <div class="text-xs text-gray-500 mt-1">
                {session.provider}/{session.model} · {session.agent}
              </div>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
