defmodule SynapsisWeb.MemoryLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    entries = list_entries()
    {:ok, assign(socket, entries: entries, scope_filter: "all", page_title: "Memory")}
  end

  @impl true
  def handle_event("create_entry", params, socket) do
    attrs = %{
      scope: params["scope"] || "global",
      key: params["key"],
      content: params["content"]
    }

    case Synapsis.Repo.insert(Synapsis.MemoryEntry.changeset(%Synapsis.MemoryEntry{}, attrs)) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(entries: list_entries())
         |> put_flash(:info, "Memory entry created")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create entry")}
    end
  end

  def handle_event("delete_entry", %{"id" => id}, socket) do
    case Synapsis.Repo.get(Synapsis.MemoryEntry, id) do
      nil -> :ok
      entry -> Synapsis.Repo.delete(entry)
    end

    {:noreply, assign(socket, entries: list_entries())}
  end

  def handle_event("filter_scope", %{"scope" => scope}, socket) do
    {:noreply, assign(socket, scope_filter: scope)}
  end

  defp list_entries do
    import Ecto.Query
    Synapsis.Repo.all(from(m in Synapsis.MemoryEntry, order_by: [desc: m.updated_at]))
  end

  defp filtered_entries(entries, "all"), do: entries
  defp filtered_entries(entries, scope), do: Enum.filter(entries, &(&1.scope == scope))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, filtered: filtered_entries(assigns.entries, assigns.scope_filter))

    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">Memory</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">Memory</h1>

        <.flash_group flash={@flash} />

        <%!-- Create Form --%>
        <div class="mb-6 bg-gray-900 rounded-lg p-4 border border-gray-800">
          <form phx-submit="create_entry" class="space-y-3">
            <div class="grid grid-cols-3 gap-3">
              <select
                name="scope"
                class="bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              >
                <option value="global">Global</option>
                <option value="project">Project</option>
                <option value="session">Session</option>
              </select>
              <input
                type="text"
                name="key"
                placeholder="Key"
                required
                class="bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
              <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
                Add Entry
              </button>
            </div>
            <textarea
              name="content"
              placeholder="Content..."
              required
              rows="3"
              class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none resize-none"
            />
          </form>
        </div>

        <%!-- Filter --%>
        <div class="flex gap-2 mb-4">
          <button
            :for={scope <- ["all", "global", "project", "session"]}
            phx-click="filter_scope"
            phx-value-scope={scope}
            class={[
              "px-3 py-1 text-sm rounded",
              if(@scope_filter == scope,
                do: "bg-blue-600 text-white",
                else: "bg-gray-800 text-gray-400 hover:text-gray-200"
              )
            ]}
          >
            {scope}
          </button>
        </div>

        <%!-- Entries List --%>
        <div class="space-y-2">
          <div
            :for={entry <- @filtered}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800"
          >
            <div class="flex justify-between items-start mb-2">
              <div>
                <span class="font-mono text-sm text-blue-400">{entry.key}</span>
                <span class="text-xs text-gray-500 ml-2">{entry.scope}</span>
              </div>
              <button
                phx-click="delete_entry"
                phx-value-id={entry.id}
                class="text-gray-600 hover:text-red-400 text-xs"
              >
                Delete
              </button>
            </div>
            <div class="text-sm text-gray-300 whitespace-pre-wrap">{entry.content}</div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
