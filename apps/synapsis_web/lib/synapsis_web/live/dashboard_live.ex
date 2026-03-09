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
    <div class="flex flex-col h-full max-w-6xl mx-auto p-6 min-h-0">
      <h1 class="text-2xl font-bold mb-4 shrink-0">Dashboard</h1>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 mb-4 shrink-0">
        <.stat_card
          icon="folder-outline"
          value={to_string(length(@projects))}
          label="Total projects"
          color="primary"
        />
        <.stat_card
          icon="chat-outline"
          value={to_string(length(@recent_sessions))}
          label="Recent sessions"
          color="secondary"
        />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6 flex-1 min-h-0">
        <.dm_card variant="bordered" class="flex flex-col min-h-0">
          <:title>Projects</:title>
          <:action>
            <.dm_link navigate={~p"/projects/new"}>
              <.dm_btn variant="primary" size="sm">
                <.dm_mdi name="plus" class="w-4 h-4 inline mr-1" /> New
              </.dm_btn>
            </.dm_link>
          </:action>

          <.empty_state
            :if={@projects == []}
            icon="folder-open-outline"
            title="No projects yet"
            description="Create one to get started."
          >
            <:action>
              <.dm_link navigate={~p"/projects/new"}>
                <.dm_btn variant="primary" size="sm">Create Project</.dm_btn>
              </.dm_link>
            </:action>
          </.empty_state>

          <div :if={@projects != []} class="flex-1 overflow-y-auto min-h-0 space-y-1">
            <.dm_link
              :for={project <- @projects}
              navigate={~p"/projects/#{project.id}"}
              class="flex items-center gap-3 w-full p-2 rounded hover:bg-base-200 transition-colors"
            >
              <.dm_mdi name="folder" class="w-5 h-5 text-primary" />
              <div class="flex-1 min-w-0">
                <div class="font-medium">{project.slug}</div>
                <div class="text-xs text-base-content/50 truncate">{project.path}</div>
              </div>
              <.dm_badge color="primary" outline size="sm">
                project
              </.dm_badge>
            </.dm_link>
          </div>
        </.dm_card>

        <.dm_card variant="bordered" class="flex flex-col min-h-0">
          <:title>Recent Sessions</:title>

          <.empty_state
            :if={@recent_sessions == []}
            icon="chat-outline"
            title="No sessions yet"
            description="Start a conversation from a project."
          />

          <div :if={@recent_sessions != []} class="flex-1 overflow-y-auto min-h-0 space-y-1">
            <.dm_link
              :for={session <- @recent_sessions}
              navigate={~p"/projects/#{session.project_id}/sessions/#{session.id}"}
              class="flex items-center gap-3 w-full p-2 rounded hover:bg-base-200 transition-colors"
            >
              <.dm_mdi name="chat-processing-outline" class="w-5 h-5 text-secondary" />
              <div class="flex-1 min-w-0">
                <div class="font-medium">
                  {session.title || "Session #{String.slice(session.id, 0, 8)}"}
                </div>
                <div class="text-xs text-base-content/50">
                  {session.provider}/{session.model}
                </div>
              </div>
              <.dm_badge color="ghost" size="sm">
                {session.agent}
              </.dm_badge>
            </.dm_link>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end
end
