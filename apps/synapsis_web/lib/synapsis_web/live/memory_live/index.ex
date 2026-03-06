defmodule SynapsisWeb.MemoryLive.Index do
  use SynapsisWeb, :live_view

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    entry =
      Synapsis.Repo.one(
        from(m in Synapsis.MemoryEntry, where: m.scope == "global" and m.key == "CLAUDE.md")
      )

    content = if entry, do: entry.content, else: ""

    {:ok,
     assign(socket,
       entry: entry,
       content: content,
       editing: false,
       draft: content,
       page_title: "Memory"
     )}
  end

  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, editing: true, draft: socket.assigns.content)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: false)}
  end

  def handle_event("update_draft", %{"content" => content}, socket) do
    {:noreply, assign(socket, draft: content)}
  end

  def handle_event("save", %{"content" => content}, socket) do
    case upsert_entry(socket.assigns.entry, content) do
      {:ok, entry} ->
        {:noreply,
         socket
         |> assign(entry: entry, content: entry.content, draft: entry.content, editing: false)
         |> put_flash(:info, "Memory saved")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save memory")}
    end
  end

  defp upsert_entry(nil, content) do
    %Synapsis.MemoryEntry{}
    |> Synapsis.MemoryEntry.changeset(%{scope: "global", key: "CLAUDE.md", content: content})
    |> Synapsis.Repo.insert()
  end

  defp upsert_entry(entry, content) do
    entry
    |> Synapsis.MemoryEntry.changeset(%{content: content})
    |> Synapsis.Repo.update()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">Memory</span>
        </div>

        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold">Memory</h1>
          <div class="flex gap-2">
            <%= if @editing do %>
              <button
                phx-click="cancel"
                class="px-4 py-2 text-sm bg-gray-800 text-gray-300 rounded hover:bg-gray-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                form="memory-form"
                class="px-4 py-2 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
              >
                Save
              </button>
            <% else %>
              <button
                phx-click="edit"
                class="px-4 py-2 text-sm bg-gray-800 text-gray-300 rounded hover:bg-gray-700"
              >
                Edit
              </button>
            <% end %>
          </div>
        </div>

        <.flash_group flash={@flash} />

        <div class="bg-gray-900 rounded-lg border border-gray-800">
          <%= if @editing do %>
            <form id="memory-form" phx-submit="save" phx-change="update_draft">
              <textarea
                name="content"
                rows="20"
                class="w-full bg-gray-900 text-gray-100 font-mono text-sm p-4 rounded-lg border-0 focus:ring-0 focus:outline-none resize-y"
              ><%= @draft %></textarea>
            </form>
          <% else %>
            <%= if @content == "" do %>
              <div class="p-8 text-center text-gray-500">
                No memory content yet. Click Edit to start writing.
              </div>
            <% else %>
              <div class="whitespace-pre-wrap font-mono text-sm text-gray-300 p-4">{@content}</div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
