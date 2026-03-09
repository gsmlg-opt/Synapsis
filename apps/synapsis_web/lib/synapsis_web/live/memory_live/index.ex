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
    <div class="max-w-4xl mx-auto p-6">
      <.dm_breadcrumb>
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Memory</:crumb>
      </.dm_breadcrumb>

      <.dm_card variant="bordered">
        <:title>Memory</:title>
        <:action>
          <%= if @editing do %>
            <.dm_btn variant="ghost" phx-click="cancel">
              Cancel
            </.dm_btn>
            <button type="submit" form="memory-form" class="btn btn-primary btn-sm">
              Save
            </button>
          <% else %>
            <.dm_btn variant="ghost" phx-click="edit">
              Edit
            </.dm_btn>
          <% end %>
        </:action>

        <%= if @editing do %>
          <.dm_form for={%{}} id="memory-form" phx-submit="save" phx-change="update_draft">
            <.dm_textarea
              name="content"
              value={@draft}
              rows={20}
              resize="vertical"
            />
          </.dm_form>
        <% else %>
          <%= if @content == "" do %>
            <.empty_state
              icon="brain"
              title="No memory content yet"
              description="Click Edit to start writing."
            />
          <% else %>
            <.dm_markdown content={@content} />
          <% end %>
        <% end %>
      </.dm_card>
    </div>
    """
  end
end
