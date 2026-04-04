defmodule SynapsisWeb.ProjectLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Projects.get(id) do
      %Synapsis.Project{} = project ->
        sessions = Synapsis.Sessions.list_by_project(project.id)
        {:ok, assign(socket, project: project, sessions: sessions, page_title: project.slug)}

      nil ->
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

  def handle_event("delete_session", %{"id" => id}, socket) do
    case Synapsis.Sessions.delete(id) do
      {:ok, _} ->
        sessions = Enum.reject(socket.assigns.sessions, &(&1.id == id))
        {:noreply, assign(socket, sessions: sessions)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete session")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/projects"}>Projects</:crumb>
        <:crumb>{@project.slug}</:crumb>
      </.breadcrumb>

      <.dm_card variant="bordered" class="mb-6">
        <:title>{@project.slug}</:title>
        <p class="text-sm text-base-content/50">{@project.path}</p>
        <:action>
          <.dm_btn variant="primary" size="sm" phx-click="create_session">
            + New Session
          </.dm_btn>
        </:action>
      </.dm_card>

      <.dm_card :if={@sessions != []} variant="bordered">
        <:title>Sessions</:title>
        <div class="space-y-1">
          <div
            :for={session <- @sessions}
            class="flex justify-between items-center w-full p-2 rounded hover:bg-base-200 transition-colors"
          >
            <.dm_link
              navigate={~p"/projects/#{@project.id}/sessions/#{session.id}"}
              class="flex-1"
            >
              <div class="font-medium">
                {session.title || "Session #{String.slice(session.id, 0, 8)}"}
              </div>
              <div class="text-xs text-base-content/50 mt-1">
                {session.provider}/{session.model} · {session.agent} ·
                <.dm_badge variant={status_color(session.status)} size="sm">
                  {session.status}
                </.dm_badge>
              </div>
            </.dm_link>
            <.dm_btn
              id={"delete-session-#{session.id}"}
              variant="ghost"
              size="sm"
              confirm="Delete this session?"
              phx-click="delete_session"
              phx-value-id={session.id}
              class="ml-2 text-base-content/40 hover:text-error"
            >
              Delete
            </.dm_btn>
          </div>
        </div>
      </.dm_card>

      <.empty_state
        :if={@sessions == []}
        icon="chat-outline"
        title="No sessions yet"
        description="Create one to start chatting."
      >
        <:action>
          <.dm_btn variant="primary" size="sm" phx-click="create_session">
            + New Session
          </.dm_btn>
        </:action>
      </.empty_state>
    </div>
    """
  end

  defp status_color("active"), do: "success"
  defp status_color("streaming"), do: "warning"
  defp status_color("error"), do: "error"
  defp status_color(_), do: "ghost"
end
