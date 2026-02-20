defmodule SynapsisWeb.DashboardLive do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, projects: [], recent_sessions: [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    projects = Synapsis.Projects.list()
    recent_sessions = Synapsis.Sessions.recent(limit: 10)

    {:noreply,
     assign(socket,
       page_title: "Dashboard",
       projects: projects,
       recent_sessions: recent_sessions
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-950 text-gray-100">
      <div class="max-w-6xl mx-auto p-6">
        <h1 class="text-2xl font-bold mb-6">Dashboard</h1>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <%!-- Projects Section --%>
          <div class="bg-gray-900 rounded-lg p-6 border border-gray-800">
            <div class="flex justify-between items-center mb-4">
              <h2 class="text-xl font-semibold">Projects</h2>
              <.link
                navigate={~p"/projects/new"}
                class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
              >
                + New
              </.link>
            </div>
            <div :if={@projects == []} class="text-gray-500 text-sm">
              No projects yet.
            </div>
            <div :for={project <- @projects} class="py-2 border-b border-gray-800 last:border-0">
              <.link navigate={~p"/projects/#{project.id}"} class="hover:text-blue-400">
                <div class="font-medium">{project.slug}</div>
                <div class="text-xs text-gray-500">{project.path}</div>
              </.link>
            </div>
          </div>

          <%!-- Recent Sessions Section --%>
          <div class="bg-gray-900 rounded-lg p-6 border border-gray-800">
            <h2 class="text-xl font-semibold mb-4">Recent Sessions</h2>
            <div :if={@recent_sessions == []} class="text-gray-500 text-sm">
              No sessions yet.
            </div>
            <div
              :for={session <- @recent_sessions}
              class="py-2 border-b border-gray-800 last:border-0"
            >
              <.link
                navigate={~p"/projects/#{session.project_id}/sessions/#{session.id}"}
                class="hover:text-blue-400"
              >
                <div class="font-medium">
                  {session.title || "Session #{String.slice(session.id, 0, 8)}"}
                </div>
                <div class="text-xs text-gray-500">
                  {session.provider}/{session.model} · {session.agent}
                </div>
              </.link>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
