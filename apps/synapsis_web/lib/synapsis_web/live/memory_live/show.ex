defmodule SynapsisWeb.MemoryLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Memory.get_semantic(id) do
      {:ok, memory} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:#{memory.scope}:#{memory.scope_id}")
        end

        # Load history events for this memory via JSONB key filter
        history =
          Synapsis.Memory.list_events(
            type: "memory_updated",
            payload_key: {"memory_id", id},
            limit: 20
          )

        {:ok,
         assign(socket,
           page_title: memory.title,
           memory: memory,
           history: history,
           editing: false,
           edit_form: build_edit_form(memory)
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Memory not found")
         |> redirect(to: ~p"/settings/memory")}
    end
  end

  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, editing: true)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: false)}
  end

  def handle_event("save", params, socket) do
    memory = socket.assigns.memory

    tags =
      (params["tags"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    changes = %{
      title: params["title"],
      summary: params["summary"],
      kind: params["kind"],
      tags: tags,
      importance: parse_float(params["importance"], memory.importance),
      confidence: parse_float(params["confidence"], memory.confidence)
    }

    # Record audit trail
    Synapsis.Memory.append_event(%{
      scope: memory.scope,
      scope_id: memory.scope_id,
      agent_id: "ui_user",
      type: "memory_updated",
      importance: 0.6,
      payload: %{
        memory_id: memory.id,
        action: "update",
        previous: %{
          title: memory.title,
          summary: memory.summary,
          kind: memory.kind,
          tags: memory.tags,
          importance: memory.importance,
          confidence: memory.confidence
        }
      }
    })

    case Synapsis.Memory.update_semantic(memory, changes) do
      {:ok, updated} ->
        Synapsis.Memory.Cache.invalidate(updated.scope, updated.scope_id)

        {:noreply,
         socket
         |> assign(memory: updated, editing: false, edit_form: build_edit_form(updated))
         |> put_flash(:info, "Memory updated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update memory")}
    end
  end

  def handle_event("archive", _params, socket) do
    case Synapsis.Memory.archive_semantic(socket.assigns.memory) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Memory archived")
         |> redirect(to: ~p"/settings/memory")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to archive")}
    end
  end

  @impl true
  def handle_info({:memory_promoted, _mem_id}, socket) do
    # Refresh the memory on any promotion event in this scope
    case Synapsis.Memory.get_semantic(socket.assigns.memory.id) do
      {:ok, updated} ->
        history =
          Synapsis.Memory.list_events(
            type: "memory_updated",
            payload_key: {"memory_id", updated.id},
            limit: 20
          )

        {:noreply,
         assign(socket, memory: updated, history: history, edit_form: build_edit_form(updated))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp build_edit_form(memory) do
    to_form(%{
      "title" => memory.title,
      "summary" => memory.summary,
      "kind" => memory.kind,
      "tags" => Enum.join(memory.tags || [], ", "),
      "importance" => to_string(memory.importance || 0.5),
      "confidence" => to_string(memory.confidence || 0.5)
    })
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(str, default) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/memory"}>Memory</:crumb>
        <:crumb>{@memory.title}</:crumb>
      </.breadcrumb>

      <.dm_card variant="bordered">
        <:title>
          <div class="flex items-center gap-2">
            {@memory.title}
            <.dm_badge size="sm" color={kind_color(@memory.kind)}>{@memory.kind}</.dm_badge>
            <.dm_badge size="sm" color={scope_color(@memory.scope)}>{@memory.scope}</.dm_badge>
            <.dm_badge size="sm" color={source_color(@memory.source)}>{@memory.source}</.dm_badge>
          </div>
        </:title>
        <:action>
          <%= if @editing do %>
            <.dm_btn variant="ghost" size="sm" phx-click="cancel_edit">Cancel</.dm_btn>
            <button type="submit" form="edit-memory-form" class="btn btn-primary btn-sm">Save</button>
          <% else %>
            <.dm_btn variant="ghost" size="sm" phx-click="edit">
              <.dm_mdi name="pencil" /> Edit
            </.dm_btn>
            <.dm_btn variant="ghost" size="sm" phx-click="archive">
              <.dm_mdi name="archive" /> Archive
            </.dm_btn>
          <% end %>
        </:action>

        <%= if @editing do %>
          <.dm_form for={@edit_form} id="edit-memory-form" phx-submit="save">
            <div class="grid grid-cols-2 gap-4 mb-4">
              <div>
                <label class="label text-base-content/60 text-sm">Kind</label>
                <select
                  name="kind"
                  class="select select-bordered w-full bg-base-200 text-base-content"
                >
                  <%= for kind <- ~w(fact decision lesson preference pattern warning) do %>
                    <option value={kind} selected={@memory.kind == kind}>{kind}</option>
                  <% end %>
                </select>
              </div>
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <label class="label text-base-content/60 text-sm">Importance</label>
                  <.dm_input
                    name="importance"
                    value={to_string(@memory.importance || 0.5)}
                    type="number"
                    step="0.1"
                    min="0"
                    max="1"
                  />
                </div>
                <div>
                  <label class="label text-base-content/60 text-sm">Confidence</label>
                  <.dm_input
                    name="confidence"
                    value={to_string(@memory.confidence || 0.5)}
                    type="number"
                    step="0.1"
                    min="0"
                    max="1"
                  />
                </div>
              </div>
            </div>
            <div class="mb-4">
              <label class="label text-base-content/60 text-sm">Title</label>
              <.dm_input name="title" value={@memory.title} />
            </div>
            <div class="mb-4">
              <label class="label text-base-content/60 text-sm">Summary</label>
              <.dm_textarea name="summary" value={@memory.summary} rows={4} />
            </div>
            <div class="mb-4">
              <label class="label text-base-content/60 text-sm">Tags (comma separated)</label>
              <.dm_input name="tags" value={Enum.join(@memory.tags || [], ", ")} />
            </div>
          </.dm_form>
        <% else %>
          <div class="space-y-4">
            <div>
              <h4 class="text-sm text-base-content/50 mb-1">Summary</h4>
              <p class="text-base-content">{@memory.summary}</p>
            </div>

            <%= if @memory.tags != [] do %>
              <div>
                <h4 class="text-sm text-base-content/50 mb-1">Tags</h4>
                <div class="flex gap-1 flex-wrap">
                  <%= for tag <- @memory.tags do %>
                    <span class="text-xs bg-base-300 text-base-content/60 px-2 py-0.5 rounded">
                      {tag}
                    </span>
                  <% end %>
                </div>
              </div>
            <% end %>

            <div class="grid grid-cols-2 gap-4">
              <.readonly_field
                label="Importance"
                value={to_string(Float.round(@memory.importance || 0.0, 2))}
              />
              <.readonly_field
                label="Confidence"
                value={to_string(Float.round(@memory.confidence || 0.0, 2))}
              />
              <.readonly_field
                label="Freshness"
                value={to_string(Float.round(@memory.freshness || 0.0, 2))}
              />
              <.readonly_field label="Access Count" value={to_string(@memory.access_count || 0)} />
              <%= if @memory.contributed_by do %>
                <.readonly_field label="Contributed By" value={@memory.contributed_by} />
              <% end %>
              <.readonly_field
                label="Created"
                value={Calendar.strftime(@memory.inserted_at, "%Y-%m-%d %H:%M:%S")}
              />
            </div>

            <%!-- Evidence section --%>
            <%= if @memory.evidence_event_ids != [] do %>
              <div>
                <h4 class="text-sm text-base-content/50 mb-1">Evidence Events</h4>
                <div class="flex gap-1 flex-wrap">
                  <%= for id <- @memory.evidence_event_ids do %>
                    <span class="text-xs bg-base-300 text-base-content/60 px-2 py-0.5 rounded font-mono">
                      {String.slice(id, 0..7)}..
                    </span>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </.dm_card>

      <%!-- History section --%>
      <%= if @history != [] do %>
        <.dm_card variant="bordered" class="mt-4">
          <:title>Change History</:title>
          <div class="space-y-2">
            <%= for event <- @history do %>
              <div class="border-l-2 border-base-300 pl-3 py-1">
                <div class="flex items-center gap-2 text-sm">
                  <.dm_badge size="xs">{get_in(event.payload, ["action"]) || "update"}</.dm_badge>
                  <span class="text-base-content/50">by {event.agent_id}</span>
                  <span class="text-base-content/40">
                    {Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M")}
                  </span>
                </div>
              </div>
            <% end %>
          </div>
        </.dm_card>
      <% end %>
    </div>
    """
  end

  defp kind_color("fact"), do: "info"
  defp kind_color("decision"), do: "primary"
  defp kind_color("lesson"), do: "success"
  defp kind_color("preference"), do: "secondary"
  defp kind_color("pattern"), do: "accent"
  defp kind_color("warning"), do: "warning"
  defp kind_color(_), do: "ghost"

  defp scope_color("shared"), do: "info"
  defp scope_color("project"), do: "primary"
  defp scope_color("agent"), do: "secondary"
  defp scope_color(_), do: "ghost"

  defp source_color("human"), do: "success"
  defp source_color("agent"), do: "info"
  defp source_color("summarizer"), do: "warning"
  defp source_color(_), do: "ghost"
end
