defmodule SynapsisWeb.ProjectLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    home = System.user_home() || "/"

    {:ok,
     assign(socket,
       projects: [],
       form: to_form(%{"path" => ""}),
       browse_path: home,
       browse_entries: [],
       show_browser: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    projects = Synapsis.Projects.list()

    {:noreply,
     apply_action(socket, socket.assigns.live_action, params) |> assign(projects: projects)}
  end

  defp apply_action(socket, :new, _params) do
    browse_path = socket.assigns.browse_path
    entries = list_directory(browse_path)

    assign(socket,
      page_title: "New Project",
      show_form: true,
      show_browser: true,
      browse_path: browse_path,
      browse_entries: entries
    )
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

  def handle_event("browse_navigate", %{"path" => path}, socket) do
    entries = list_directory(path)
    {:noreply, assign(socket, browse_path: path, browse_entries: entries)}
  end

  def handle_event("select_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, form: to_form(%{"path" => path}))}
  end

  def handle_event("update_path", %{"path" => path}, socket) do
    if File.dir?(path) do
      entries = list_directory(path)

      {:noreply,
       assign(socket,
         form: to_form(%{"path" => path}),
         browse_path: path,
         browse_entries: entries
       )}
    else
      parent = Path.dirname(path)

      if File.dir?(parent) do
        entries = list_directory(parent)

        {:noreply,
         assign(socket,
           form: to_form(%{"path" => path}),
           browse_path: parent,
           browse_entries: entries
         )}
      else
        {:noreply, assign(socket, form: to_form(%{"path" => path}))}
      end
    end
  end

  def handle_event("toggle_browser", _params, socket) do
    show = !socket.assigns.show_browser

    socket =
      if show do
        entries = list_directory(socket.assigns.browse_path)
        assign(socket, show_browser: true, browse_entries: entries)
      else
        assign(socket, show_browser: false)
      end

    {:noreply, socket}
  end

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.map(fn name ->
          full = Path.join(path, name)
          %{name: name, path: full, dir?: File.dir?(full)}
        end)
        |> Enum.filter(fn entry -> not String.starts_with?(entry.name, ".") end)

      {:error, _} ->
        []
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
        <.dm_form for={@form} phx-submit="create_project" phx-change="update_path">
          <div class="flex gap-2 items-end">
            <div class="flex-1">
              <.dm_input
                type="text"
                name="path"
                value={@form["path"].value}
                label="Project Path"
                placeholder="Project path (e.g., /home/user/myproject)"
              />
            </div>
            <.dm_btn type="button" variant="ghost" size="sm" phx-click="toggle_browser">
              <.dm_mdi name="folder-search-outline" class="w-5 h-5" /> Browse
            </.dm_btn>
            <.dm_btn type="submit" variant="primary" size="sm">
              Create
            </.dm_btn>
          </div>
        </.dm_form>

        <div :if={@show_browser} class="mt-4 border border-base-300 rounded-lg overflow-hidden">
          <div class="bg-base-200 px-3 py-2 flex items-center gap-2 text-sm font-mono">
            <.dm_mdi name="folder-outline" class="w-4 h-4 text-primary" />
            <span class="truncate">{@browse_path}</span>
            <.dm_btn
              :if={@browse_path != "/"}
              type="button"
              variant="ghost"
              size="xs"
              phx-click="browse_navigate"
              phx-value-path={Path.dirname(@browse_path)}
            >
              <.dm_mdi name="arrow-up" class="w-4 h-4" />
            </.dm_btn>
          </div>
          <div class="max-h-64 overflow-y-auto divide-y divide-base-200">
            <div
              :for={entry <- @browse_entries}
              class="flex items-center gap-2 px-3 py-1.5 hover:bg-base-200 cursor-pointer text-sm"
            >
              <div
                :if={entry.dir?}
                class="flex items-center gap-2 flex-1"
                phx-click="browse_navigate"
                phx-value-path={entry.path}
              >
                <.dm_mdi name="folder" class="w-4 h-4 text-warning" />
                <span>{entry.name}</span>
              </div>
              <div :if={!entry.dir?} class="flex items-center gap-2 flex-1 text-base-content/50">
                <.dm_mdi name="file-outline" class="w-4 h-4" />
                <span>{entry.name}</span>
              </div>
              <.dm_btn
                :if={entry.dir?}
                type="button"
                variant="ghost"
                size="xs"
                phx-click="select_path"
                phx-value-path={entry.path}
              >
                Select
              </.dm_btn>
            </div>
            <div
              :if={@browse_entries == []}
              class="px-3 py-4 text-center text-base-content/50 text-sm"
            >
              Empty directory
            </div>
          </div>
        </div>
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
