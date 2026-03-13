defmodule SynapsisWeb.WorkspaceLive.Explorer do
  use SynapsisWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    path = params["path"] || "/"
    {:ok, resources} = Synapsis.Workspace.list(path, sort: :path, limit: 200)

    {:ok,
     assign(socket,
       page_title: "Workspace",
       current_path: path,
       resources: resources,
       search_query: "",
       search_results: nil,
       selected: nil,
       editing: false,
       edit_content: ""
     )}
  end

  @impl true
  def handle_params(%{"path" => path}, _uri, socket) do
    {:ok, resources} = Synapsis.Workspace.list(path, sort: :path, limit: 200)

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

  def handle_event("search", %{"query" => query}, socket) when byte_size(query) > 0 do
    {:ok, results} = Synapsis.Workspace.search(query, limit: 20)
    {:noreply, assign(socket, search_query: query, search_results: results)}
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

  def handle_event("save_edit", %{"content" => content}, socket) do
    selected = socket.assigns.selected

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/"}>Home</:crumb>
        <:crumb>Workspace</:crumb>
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
              class="text-center py-8 text-base-content/50"
            >
              <.dm_mdi name="folder-open-outline" class="w-8 h-8 mx-auto mb-2" />
              <p>No documents found</p>
            </div>

            <div class="space-y-1">
              <div
                :for={resource <- display_resources(assigns)}
                class={[
                  "flex items-center gap-3 p-2 rounded cursor-pointer hover:bg-base-200 transition-colors",
                  @selected && @selected.id == resource.id && "bg-base-200"
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
                  <div class="text-xs text-base-content/50 truncate">{resource.path}</div>
                </div>
                <.dm_badge
                  color={lifecycle_color(resource.lifecycle)}
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

            <div class="flex gap-2 mb-4 text-xs text-base-content/60">
              <.dm_badge color={lifecycle_color(@selected.lifecycle)} size="sm">
                {@selected.lifecycle}
              </.dm_badge>
              <.dm_badge color="ghost" size="sm">v{@selected.version}</.dm_badge>
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
                  class="w-full font-mono text-sm bg-base-200 rounded p-4 border border-base-300 focus:border-primary focus:outline-none"
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
              class="prose prose-sm max-w-none bg-base-200 rounded p-4 overflow-auto max-h-[60vh]"
            >
              <pre class="whitespace-pre-wrap text-sm">{@selected.content || "(empty)"}</pre>
            </div>
          </.dm_card>
        </div>
      </div>
    </div>
    """
  end

  # Helpers

  defp display_resources(%{search_results: results}) when is_list(results), do: results
  defp display_resources(%{resources: resources}), do: resources

  defp parent_path(path) do
    Synapsis.Workspace.PathResolver.parent(path)
  end

  defp filename(path) do
    path |> String.split("/") |> List.last() || path
  end

  defp kind_icon(:document), do: "file-document-outline"
  defp kind_icon(:attachment), do: "paperclip"
  defp kind_icon(:handoff), do: "swap-horizontal"
  defp kind_icon(:session_scratch), do: "pencil-outline"
  defp kind_icon(_), do: "file-outline"

  defp kind_color(:document), do: "text-primary"
  defp kind_color(:attachment), do: "text-warning"
  defp kind_color(:handoff), do: "text-info"
  defp kind_color(:session_scratch), do: "text-base-content/50"
  defp kind_color(_), do: "text-base-content/60"

  defp lifecycle_color(:scratch), do: "ghost"
  defp lifecycle_color(:draft), do: "warning"
  defp lifecycle_color(:shared), do: "info"
  defp lifecycle_color(:published), do: "success"
  defp lifecycle_color(:archived), do: "ghost"
  defp lifecycle_color(_), do: "ghost"
end
