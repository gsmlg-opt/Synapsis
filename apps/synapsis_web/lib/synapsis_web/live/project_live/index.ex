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
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">Projects</h1>
          <.link
            navigate={~p"/projects/new"}
            class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + New Project
          </.link>
        </div>

        <.flash_group flash={@flash} />

        <div :if={@show_form} class="mb-6 bg-gray-900 rounded-lg p-4 border border-gray-800">
          <form phx-submit="create_project" class="flex gap-2">
            <input
              type="text"
              name="path"
              placeholder="Project path (e.g., /home/user/myproject)"
              class="flex-1 bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              Create
            </button>
          </form>
        </div>

        <div class="space-y-2">
          <div
            :for={project <- @projects}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800 hover:border-gray-700"
          >
            <.link navigate={~p"/projects/#{project.id}"}>
              <div class="font-medium text-blue-400">{project.slug}</div>
              <div class="text-sm text-gray-500 mt-1">{project.path}</div>
            </.link>
          </div>

          <div :if={@projects == []} class="text-center text-gray-500 py-12">
            No projects yet. Create one to get started.
          </div>
        </div>
      </div>
    </div>
    """
  end
end
