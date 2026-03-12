defmodule SynapsisWeb.MemoryLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:cache_invalidation")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Memory",
       active_tab: "knowledge",
       # Knowledge tab
       scope_filter: "all",
       kind_filter: "all",
       source_filter: "all",
       memories: [],
       # Events tab
       events: [],
       events_type_filter: "all",
       # Checkpoints tab
       checkpoints: [],
       # Create form
       show_create: false,
       create_form:
         to_form(%{
           "kind" => "fact",
           "scope" => "shared",
           "title" => "",
           "summary" => "",
           "tags" => ""
         })
     )
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply, assign(socket, show_create: true)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> assign(active_tab: tab) |> load_data()}
  end

  def handle_event("filter_scope", %{"scope" => scope}, socket) do
    {:noreply, socket |> assign(scope_filter: scope) |> load_knowledge()}
  end

  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    {:noreply, socket |> assign(kind_filter: kind) |> load_knowledge()}
  end

  def handle_event("filter_source", %{"source" => source}, socket) do
    {:noreply, socket |> assign(source_filter: source) |> load_knowledge()}
  end

  def handle_event("filter_event_type", %{"type" => type}, socket) do
    {:noreply, socket |> assign(events_type_filter: type) |> load_events()}
  end

  def handle_event("show_create", _params, socket) do
    {:noreply, assign(socket, show_create: true)}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, show_create: false)}
  end

  def handle_event("create_memory", params, socket) do
    tags =
      (params["tags"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    scope = params["scope"] || "shared"

    attrs = %{
      scope: scope,
      scope_id: if(scope == "shared", do: "", else: params["scope_id"] || ""),
      kind: params["kind"] || "fact",
      title: params["title"] || "",
      summary: params["summary"] || "",
      tags: tags,
      source: "human",
      importance: 1.0,
      confidence: 1.0,
      freshness: 1.0
    }

    case Synapsis.Memory.store_semantic(attrs) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> assign(show_create: false)
         |> put_flash(:info, "Memory saved")
         |> load_knowledge()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save memory")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    case Synapsis.Memory.get_semantic(id) do
      {:ok, memory} ->
        Synapsis.Memory.archive_semantic(memory)
        {:noreply, socket |> put_flash(:info, "Memory archived") |> load_knowledge()}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:invalidate_scope, _, _}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:memory_promoted, _}, socket), do: {:noreply, load_data(socket)}
  def handle_info({:memory_updated, _}, socket), do: {:noreply, load_data(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load_data(socket) do
    case socket.assigns.active_tab do
      "knowledge" -> load_knowledge(socket)
      "events" -> load_events(socket)
      "checkpoints" -> load_checkpoints(socket)
      _ -> socket
    end
  end

  defp load_knowledge(socket) do
    filters = [active: true, limit: 50]

    filters =
      case socket.assigns.scope_filter do
        "all" -> filters
        scope -> [{:scope, scope} | filters]
      end

    filters =
      case socket.assigns.kind_filter do
        "all" -> filters
        kind -> [{:kind, kind} | filters]
      end

    filters =
      case socket.assigns.source_filter do
        "all" -> filters
        source -> [{:source, source} | filters]
      end

    memories = Synapsis.Memory.list_semantic(filters)
    assign(socket, memories: memories)
  end

  defp load_events(socket) do
    filters = [limit: 50]

    filters =
      case socket.assigns.events_type_filter do
        "all" -> filters
        type -> [{:type, type} | filters]
      end

    events = Synapsis.Memory.list_events(filters)
    assign(socket, events: events)
  end

  defp load_checkpoints(socket) do
    checkpoints = Synapsis.Memory.list_checkpoints(limit: 50)
    assign(socket, checkpoints: checkpoints)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6">
      <.dm_breadcrumb>
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Memory</:crumb>
      </.dm_breadcrumb>

      <%!-- Tab navigation --%>
      <div class="flex gap-2 mb-4">
        <.dm_btn
          variant={if @active_tab == "knowledge", do: "primary", else: "ghost"}
          size="sm"
          phx-click="switch_tab"
          phx-value-tab="knowledge"
        >
          <.dm_mdi name="brain" /> Knowledge
        </.dm_btn>
        <.dm_btn
          variant={if @active_tab == "events", do: "primary", else: "ghost"}
          size="sm"
          phx-click="switch_tab"
          phx-value-tab="events"
        >
          <.dm_mdi name="timeline-text" /> Events
        </.dm_btn>
        <.dm_btn
          variant={if @active_tab == "checkpoints", do: "primary", else: "ghost"}
          size="sm"
          phx-click="switch_tab"
          phx-value-tab="checkpoints"
        >
          <.dm_mdi name="content-save-check" /> Checkpoints
        </.dm_btn>
      </div>

      <%!-- Knowledge tab --%>
      <%= if @active_tab == "knowledge" do %>
        <div class="mb-4 flex flex-wrap gap-2 items-center">
          <select
            class="select select-sm select-bordered bg-base-200 text-base-content"
            phx-change="filter_scope"
            name="scope"
          >
            <option value="all" selected={@scope_filter == "all"}>All Scopes</option>
            <option value="shared" selected={@scope_filter == "shared"}>Shared</option>
            <option value="project" selected={@scope_filter == "project"}>Project</option>
            <option value="agent" selected={@scope_filter == "agent"}>Agent</option>
          </select>

          <select
            class="select select-sm select-bordered bg-base-200 text-base-content"
            phx-change="filter_kind"
            name="kind"
          >
            <option value="all" selected={@kind_filter == "all"}>All Kinds</option>
            <option value="fact" selected={@kind_filter == "fact"}>Fact</option>
            <option value="decision" selected={@kind_filter == "decision"}>Decision</option>
            <option value="lesson" selected={@kind_filter == "lesson"}>Lesson</option>
            <option value="preference" selected={@kind_filter == "preference"}>Preference</option>
            <option value="pattern" selected={@kind_filter == "pattern"}>Pattern</option>
            <option value="warning" selected={@kind_filter == "warning"}>Warning</option>
          </select>

          <select
            class="select select-sm select-bordered bg-base-200 text-base-content"
            phx-change="filter_source"
            name="source"
          >
            <option value="all" selected={@source_filter == "all"}>All Sources</option>
            <option value="human" selected={@source_filter == "human"}>Human</option>
            <option value="agent" selected={@source_filter == "agent"}>Agent</option>
            <option value="summarizer" selected={@source_filter == "summarizer"}>Summarizer</option>
          </select>

          <div class="flex-1" />

          <.dm_btn variant="primary" size="sm" phx-click="show_create">
            <.dm_mdi name="plus" /> New Memory
          </.dm_btn>
        </div>

        <%!-- Create form --%>
        <%= if @show_create do %>
          <.dm_card variant="bordered" class="mb-4">
            <:title>New Memory</:title>
            <.dm_form for={@create_form} id="create-memory-form" phx-submit="create_memory">
              <div class="grid grid-cols-2 gap-4 mb-4">
                <div>
                  <label class="label text-base-content/60 text-sm">Scope</label>
                  <select
                    name="scope"
                    class="select select-bordered w-full bg-base-200 text-base-content"
                  >
                    <option value="shared">Shared</option>
                    <option value="project" selected>Project</option>
                    <option value="agent">Agent</option>
                  </select>
                </div>
                <div>
                  <label class="label text-base-content/60 text-sm">Kind</label>
                  <select
                    name="kind"
                    class="select select-bordered w-full bg-base-200 text-base-content"
                  >
                    <option value="fact" selected>Fact</option>
                    <option value="decision">Decision</option>
                    <option value="lesson">Lesson</option>
                    <option value="preference">Preference</option>
                    <option value="pattern">Pattern</option>
                    <option value="warning">Warning</option>
                  </select>
                </div>
              </div>
              <div class="mb-4">
                <label class="label text-base-content/60 text-sm">Title</label>
                <.dm_input name="title" value="" placeholder="Short title (~10 words)" required />
              </div>
              <div class="mb-4">
                <label class="label text-base-content/60 text-sm">Summary</label>
                <.dm_textarea
                  name="summary"
                  value=""
                  placeholder="1-3 sentences"
                  rows={3}
                  required
                />
              </div>
              <div class="mb-4">
                <label class="label text-base-content/60 text-sm">Tags (comma separated)</label>
                <.dm_input name="tags" value="" placeholder="tag1, tag2, tag3" />
              </div>
              <div class="flex gap-2 justify-end">
                <.dm_btn variant="ghost" phx-click="cancel_create">Cancel</.dm_btn>
                <.dm_btn variant="primary" type="submit">Save</.dm_btn>
              </div>
            </.dm_form>
          </.dm_card>
        <% end %>

        <%!-- Memory list --%>
        <%= if @memories == [] do %>
          <.empty_state
            icon="brain"
            title="No memories yet"
            description="Memories are created by agents during sessions, or you can add them manually."
          />
        <% else %>
          <div class="grid gap-3">
            <%= for memory <- @memories do %>
              <.dm_card variant="bordered" class="hover:border-primary/30 transition-colors">
                <div class="flex items-start justify-between gap-2">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 mb-1 flex-wrap">
                      <.dm_link
                        navigate={~p"/settings/memory/#{memory.id}"}
                        class="font-semibold text-base-content hover:text-primary"
                      >
                        {memory.title}
                      </.dm_link>
                      <.dm_badge size="xs" color={kind_color(memory.kind)}>
                        {memory.kind}
                      </.dm_badge>
                      <.dm_badge size="xs" color={scope_color(memory.scope)}>
                        {memory.scope}
                      </.dm_badge>
                      <.dm_badge size="xs" color={source_color(memory.source)}>
                        {memory.source}
                      </.dm_badge>
                    </div>
                    <p class="text-base-content/70 text-sm">{memory.summary}</p>
                    <%= if memory.tags != [] do %>
                      <div class="flex gap-1 mt-1 flex-wrap">
                        <%= for tag <- memory.tags do %>
                          <span class="text-xs bg-base-300 text-base-content/60 px-1.5 py-0.5 rounded">
                            {tag}
                          </span>
                        <% end %>
                      </div>
                    <% end %>
                    <div class="flex gap-3 mt-1 text-xs text-base-content/40">
                      <span>Importance: {Float.round(memory.importance || 0.0, 1)}</span>
                      <span>Confidence: {Float.round(memory.confidence || 0.0, 1)}</span>
                      <%= if memory.contributed_by do %>
                        <span>By: {memory.contributed_by}</span>
                      <% end %>
                    </div>
                  </div>
                  <.dm_btn
                    variant="ghost"
                    size="xs"
                    phx-click="archive"
                    phx-value-id={memory.id}
                  >
                    <.dm_mdi name="archive" />
                  </.dm_btn>
                </div>
              </.dm_card>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <%!-- Events tab --%>
      <%= if @active_tab == "events" do %>
        <div class="mb-4">
          <select
            class="select select-sm select-bordered bg-base-200 text-base-content"
            phx-change="filter_event_type"
            name="type"
          >
            <option value="all" selected={@events_type_filter == "all"}>All Types</option>
            <option value="tool_called">Tool Called</option>
            <option value="tool_succeeded">Tool Succeeded</option>
            <option value="tool_failed">Tool Failed</option>
            <option value="message_added">Message Added</option>
            <option value="task_completed">Task Completed</option>
            <option value="task_failed">Task Failed</option>
            <option value="memory_promoted">Memory Promoted</option>
            <option value="memory_updated">Memory Updated</option>
          </select>
        </div>

        <%= if @events == [] do %>
          <.empty_state
            icon="timeline-text"
            title="No events yet"
            description="Events are recorded as agents work — tool calls, completions, and memory changes."
          />
        <% else %>
          <.dm_table data={@events}>
            <:col :let={event} label="Type">
              <.dm_badge size="xs">{event.type}</.dm_badge>
            </:col>
            <:col :let={event} label="Agent">{event.agent_id}</:col>
            <:col :let={event} label="Scope">{event.scope}:{event.scope_id}</:col>
            <:col :let={event} label="Importance">
              {Float.round(event.importance || 0.0, 1)}
            </:col>
            <:col :let={event} label="Time">
              {Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M:%S")}
            </:col>
          </.dm_table>
        <% end %>
      <% end %>

      <%!-- Checkpoints tab --%>
      <%= if @active_tab == "checkpoints" do %>
        <%= if @checkpoints == [] do %>
          <.empty_state
            icon="content-save-check"
            title="No checkpoints yet"
            description="Checkpoints are created during agent sessions for crash recovery."
          />
        <% else %>
          <.dm_table data={@checkpoints}>
            <:col :let={cp} label="Workflow">{cp.workflow}</:col>
            <:col :let={cp} label="Node">{cp.node}</:col>
            <:col :let={cp} label="Version">{cp.state_version}</:col>
            <:col :let={cp} label="Session">{String.slice(cp.session_id, 0..7)}..</:col>
            <:col :let={cp} label="Time">
              {Calendar.strftime(cp.inserted_at, "%Y-%m-%d %H:%M:%S")}
            </:col>
          </.dm_table>
        <% end %>
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
