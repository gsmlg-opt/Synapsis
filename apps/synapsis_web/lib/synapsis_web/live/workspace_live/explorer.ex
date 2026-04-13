defmodule SynapsisWeb.WorkspaceLive.Explorer do
  use SynapsisWeb, :live_view
  require Logger

  @impl true
  def mount(params, _session, socket) do
    path = params["path"] || "/"
    {:ok, resources} = Synapsis.Workspace.list(path, sort: :path, limit: 200)

    # Subscribe to workspace changes for real-time updates
    if connected?(socket), do: subscribe_workspace_changes(path)

    {:ok,
     assign(socket,
       page_title: "Workspace",
       current_path: path,
       resources: resources,
       search_query: "",
       search_results: nil,
       selected: nil,
       editing: false,
       edit_content: "",
       subscribed_project: extract_project_id(path)
     )}
  end

  @impl true
  def handle_params(%{"path" => path}, _uri, socket) do
    {:ok, resources} = Synapsis.Workspace.list(path, sort: :path, limit: 200)

    socket =
      if connected?(socket) do
        resubscribe_workspace_changes(socket, path)
      else
        socket
      end

    {:noreply,
     assign(socket, current_path: path, resources: resources, selected: nil, editing: false)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, push_patch(socket, to: ~p"/workspace?path=#{path}")}
  end

  def handle_event("select", %{"id" => id}, socket) do
    case Synapsis.Workspace.read(id) do
      {:ok, resource} ->
        {:noreply, assign(socket, selected: resource, editing: false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Document not found")}
    end
  end

  @max_search_query_bytes 1_000

  def handle_event("search", %{"query" => query}, socket)
      when byte_size(query) > 0 and byte_size(query) <= @max_search_query_bytes do
    {:ok, results} = Synapsis.Workspace.search(query, limit: 20)
    {:noreply, assign(socket, search_query: query, search_results: results)}
  end

  def handle_event("search", %{"query" => query}, socket)
      when byte_size(query) > @max_search_query_bytes do
    {:noreply, put_flash(socket, :error, "Search query too long")}
  end

  def handle_event("search", _params, socket) do
    {:noreply, assign(socket, search_query: "", search_results: nil)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "", search_results: nil)}
  end

  def handle_event("edit", _params, socket) do
    content = (socket.assigns.selected && socket.assigns.selected.content) || ""
    {:noreply, assign(socket, editing: true, edit_content: content)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: false)}
  end

  @max_content_bytes 1_000_000

  def handle_event("save_edit", %{"content" => content}, socket)
      when byte_size(content) > @max_content_bytes do
    {:noreply, put_flash(socket, :error, "Content too large")}
  end

  def handle_event("save_edit", %{"content" => content}, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, put_flash(socket, :error, "No document selected")}

      selected ->
        case Synapsis.Workspace.write(selected.path, content, %{author: "user"}) do
          {:ok, updated} ->
            {:ok, resources} =
              Synapsis.Workspace.list(socket.assigns.current_path, sort: :path, limit: 200)

            {:noreply,
             socket
             |> assign(selected: updated, editing: false, resources: resources)
             |> put_flash(:info, "Document saved")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to save document")}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Synapsis.Workspace.delete(id) do
      :ok ->
        {:ok, resources} =
          Synapsis.Workspace.list(socket.assigns.current_path, sort: :path, limit: 200)

        {:noreply,
         socket
         |> assign(selected: nil, resources: resources, editing: false)
         |> put_flash(:info, "Document deleted")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Document not found")}
    end
  end

  def handle_event("promote", _params, socket) do
    selected = socket.assigns.selected

    if selected && promotable?(selected) do
      project_id = extract_project_id(selected.path)
      new_path = promote_path(selected.path, project_id)

      case Synapsis.Workspace.write(new_path, selected.content || "", %{
             author: "user",
             lifecycle: :shared,
             visibility: :project_shared,
             metadata: Map.put(selected.metadata, "promoted_from", selected.path)
           }) do
        {:ok, promoted} ->
          {:ok, resources} =
            Synapsis.Workspace.list(socket.assigns.current_path, sort: :path, limit: 200)

          {:noreply,
           socket
           |> assign(selected: promoted, resources: resources)
           |> put_flash(:info, "Promoted to project level")}

        {:error, reason} ->
          Logger.warning("workspace_promote_failed", reason: inspect(reason))
          {:noreply, put_flash(socket, :error, "Failed to promote document")}
      end
    else
      {:noreply, put_flash(socket, :error, "Document cannot be promoted")}
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub handler — real-time updates when agents write (WS-18.5)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:workspace_changed, _payload}, socket) do
    {:ok, resources} =
      Synapsis.Workspace.list(socket.assigns.current_path, sort: :path, limit: 200)

    selected =
      if socket.assigns.selected do
        case Synapsis.Workspace.read(socket.assigns.selected.id) do
          {:ok, resource} -> resource
          {:error, _} -> nil
        end
      end

    {:noreply, assign(socket, resources: resources, selected: selected)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/"}>Home</:crumb>
        <:crumb to={~p"/workspace"}>Workspace</:crumb>
        <:crumb
          :for={{segment, path} <- path_segments(@current_path)}
          to={~p"/workspace?path=#{path}"}
        >
          {segment}
        </:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Workspace Explorer</h1>
      </div>

      <%!-- Search bar --%>
      <.dm_card variant="bordered" class="mb-6">
        <.dm_form for={%{}} phx-submit="search" class="flex gap-2 items-end">
          <div class="flex-1">
            <.dm_input
              type="text"
              name="query"
              value={@search_query}
              placeholder="Search workspace documents..."
              label="Search"
            />
          </div>
          <.dm_btn type="submit" variant="primary">
            Search
          </.dm_btn>
          <.dm_btn
            :if={@search_results}
            type="button"
            variant="ghost"
            phx-click="clear_search"
          >
            Clear
          </.dm_btn>
        </.dm_form>
      </.dm_card>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- File list --%>
        <div class={if @selected, do: "lg:col-span-1", else: "lg:col-span-3"}>
          <.dm_card variant="bordered">
            <:title>
              <div class="flex items-center gap-2">
                <.dm_mdi name="folder-outline" class="w-5 h-5" />
                <span class="font-mono text-sm">{@current_path}</span>
              </div>
            </:title>

            <%!-- Path navigation --%>
            <div :if={@current_path != "/"} class="mb-4">
              <.dm_btn
                variant="ghost"
                size="sm"
                phx-click="navigate"
                phx-value-path={parent_path(@current_path)}
              >
                <.dm_mdi name="arrow-up" class="w-4 h-4 mr-1" /> Up
              </.dm_btn>
            </div>

            <div
              :if={display_resources(assigns) == []}
              class="text-center py-8 text-on-surface-variant"
            >
              <.dm_mdi name="folder-open-outline" class="w-8 h-8 mx-auto mb-2" />
              <p>No documents found</p>
            </div>

            <div class="space-y-1">
              <div
                :for={resource <- display_resources(assigns)}
                class={[
                  "flex items-center gap-3 p-2 rounded cursor-pointer hover:bg-surface-container transition-colors",
                  @selected && @selected.id == resource.id && "bg-surface-container"
                ]}
                phx-click="select"
                phx-value-id={resource.id}
              >
                <.dm_mdi
                  name={kind_icon(resource.kind)}
                  class={"w-5 h-5 #{kind_color(resource.kind)}"}
                />
                <div class="flex-1 min-w-0">
                  <div class="text-sm font-medium truncate">{filename(resource.path)}</div>
                  <div class="text-xs text-on-surface-variant truncate">{resource.path}</div>
                </div>
                <.dm_badge
                  variant={lifecycle_color(resource.lifecycle)}
                  size="sm"
                >
                  {resource.lifecycle}
                </.dm_badge>
              </div>
            </div>
          </.dm_card>
        </div>

        <%!-- Preview/Edit panel --%>
        <div :if={@selected} class="lg:col-span-2">
          <.dm_card variant="bordered">
            <:title>
              <div class="flex items-center justify-between w-full">
                <div class="flex items-center gap-2">
                  <.dm_mdi name={kind_icon(@selected.kind)} class="w-5 h-5" />
                  <span class="font-mono text-sm">{filename(@selected.path)}</span>
                </div>
                <div class="flex gap-1">
                  <.dm_btn
                    :if={promotable?(@selected)}
                    variant="ghost"
                    size="sm"
                    phx-click="promote"
                    title="Promote to project level"
                  >
                    <.dm_mdi name="arrow-up-bold" class="w-4 h-4 text-success" />
                  </.dm_btn>
                  <.dm_btn
                    :if={!@editing}
                    variant="ghost"
                    size="sm"
                    phx-click="edit"
                  >
                    <.dm_mdi name="pencil" class="w-4 h-4" />
                  </.dm_btn>
                  <.dm_btn
                    variant="ghost"
                    size="sm"
                    phx-click="delete"
                    phx-value-id={@selected.id}
                    data-confirm="Delete this document?"
                  >
                    <.dm_mdi name="delete-outline" class="w-4 h-4 text-error" />
                  </.dm_btn>
                </div>
              </div>
            </:title>

            <div class="flex gap-2 mb-4 text-xs text-on-surface-variant">
              <.dm_badge variant={lifecycle_color(@selected.lifecycle)} size="sm">
                {@selected.lifecycle}
              </.dm_badge>
              <.dm_badge variant="ghost" size="sm">v{@selected.version}</.dm_badge>
              <span :if={@selected.updated_at}>
                Updated: {Calendar.strftime(@selected.updated_at, "%Y-%m-%d %H:%M")}
              </span>
            </div>

            <%!-- Edit mode --%>
            <div :if={@editing}>
              <.dm_form for={%{}} phx-submit="save_edit">
                <textarea
                  name="content"
                  rows="20"
                  class="w-full font-mono text-sm bg-surface-container rounded p-4 border border-outline-variant focus:border-primary focus:outline-none"
                >{@edit_content}</textarea>
                <div class="flex gap-2 mt-3">
                  <.dm_btn type="submit" variant="primary" size="sm">
                    Save
                  </.dm_btn>
                  <.dm_btn type="button" variant="ghost" size="sm" phx-click="cancel_edit">
                    Cancel
                  </.dm_btn>
                </div>
              </.dm_form>
            </div>

            <%!-- Read-only mode --%>
            <div
              :if={!@editing}
              class="prose prose-sm max-w-none bg-surface-container rounded p-4 overflow-auto max-h-[60vh]"
            >
              <pre class="whitespace-pre-wrap text-sm">{@selected.content || "(empty)"}</pre>
            </div>
          </.dm_card>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp display_resources(%{search_results: results}) when is_list(results), do: results
  defp display_resources(%{resources: resources}), do: resources

  defp parent_path(path) do
    Synapsis.Workspace.PathResolver.parent(path)
  end

  defp path_segments("/"), do: []

  defp path_segments(path) do
    segments = path |> String.trim("/") |> String.split("/")

    segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, idx} ->
      prefix = "/" <> Enum.join(Enum.take(segments, idx + 1), "/")
      {segment, prefix}
    end)
  end

  defp filename(path) do
    path |> String.split("/") |> List.last() || path
  end

  defp kind_icon(:document), do: "file-document-outline"
  defp kind_icon(:attachment), do: "paperclip"
  defp kind_icon(:handoff), do: "swap-horizontal"
  defp kind_icon(:session_scratch), do: "pencil-outline"
  defp kind_icon(:skill), do: "lightning-bolt"
  defp kind_icon(:memory), do: "brain"
  defp kind_icon(:todo), do: "checkbox-marked-outline"
  defp kind_icon(_), do: "file-outline"

  defp kind_color(:document), do: "text-primary"
  defp kind_color(:attachment), do: "text-warning"
  defp kind_color(:handoff), do: "text-info"
  defp kind_color(:session_scratch), do: "text-on-surface-variant"
  defp kind_color(:skill), do: "text-secondary"
  defp kind_color(:memory), do: "text-accent"
  defp kind_color(:todo), do: "text-success"
  defp kind_color(_), do: "text-on-surface-variant"

  defp lifecycle_color(:scratch), do: "ghost"
  defp lifecycle_color(:draft), do: "warning"
  defp lifecycle_color(:shared), do: "info"
  defp lifecycle_color(:published), do: "success"
  defp lifecycle_color(:archived), do: "ghost"
  defp lifecycle_color(_), do: "ghost"

  defp promotable?(%{lifecycle: lifecycle, path: path})
       when lifecycle in [:scratch, :draft] do
    String.contains?(path, "/sessions/")
  end

  defp promotable?(_), do: false

  defp extract_project_id(path) do
    case String.split(path, "/", trim: true) do
      ["projects", project_id | _] -> project_id
      _ -> nil
    end
  end

  defp promote_path(session_path, project_id) do
    filename = session_path |> String.split("/") |> List.last() || "untitled"
    "/projects/#{project_id}/notes/#{String.downcase(filename)}"
  end

  defp subscribe_workspace_changes(path) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

    case extract_project_id(path) do
      nil -> :ok
      project_id -> Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:#{project_id}")
    end
  end

  # Unsubscribe from old project topic, subscribe to new one, update tracking assign
  defp resubscribe_workspace_changes(socket, path) do
    old_project = socket.assigns[:subscribed_project]
    new_project = extract_project_id(path)

    if old_project && old_project != new_project do
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "workspace:#{old_project}")
    end

    if new_project && new_project != old_project do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:#{new_project}")
    end

    assign(socket, :subscribed_project, new_project)
  end
end
