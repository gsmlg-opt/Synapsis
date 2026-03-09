defmodule SynapsisWeb.ProjectLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, projects: [], form: to_form(%{"path" => ""}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    projects = Synapsis.Projects.list()

    {:noreply,
     apply_action(socket, socket.assigns.live_action, params) |> assign(projects: projects)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, page_title: "New Project", show_form: true)
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Projects", show_form: false)
  end

  @impl true
  def handle_event("create_project", %{"path" => path}, socket) do
    case Synapsis.Projects.find_or_create(path) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created")
         |> push_navigate(to: ~p"/projects/#{project.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create project")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Projects</h1>
        <.dm_link navigate={~p"/projects/new"}>
          <.dm_btn variant="primary" size="sm">+ New Project</.dm_btn>
        </.dm_link>
      </div>

      <.dm_card :if={@show_form} variant="bordered" class="mb-6">
        <.dm_form for={@form} phx-submit="create_project" class="flex gap-2">
          <.dm_input
            type="text"
            name="path"
            value=""
            label="Project Path"
            placeholder="Project path (e.g., /home/user/myproject)"
            class="flex-1"
          />
          <:actions>
            <.dm_btn type="submit" variant="primary">
              Create
            </.dm_btn>
          </:actions>
        </.dm_form>
      </.dm_card>

      <.dm_card :if={@projects != []} variant="bordered">
        <:title>All Projects</:title>
        <div class="space-y-1">
          <.dm_link
            :for={project <- @projects}
            navigate={~p"/projects/#{project.id}"}
            class="flex flex-col gap-1 w-full p-2 rounded hover:bg-base-200 transition-colors"
          >
            <div class="font-medium text-primary">{project.slug}</div>
            <div class="text-sm text-base-content/50">{project.path}</div>
          </.dm_link>
        </div>
      </.dm_card>

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
    </div>
    """
  end
end
