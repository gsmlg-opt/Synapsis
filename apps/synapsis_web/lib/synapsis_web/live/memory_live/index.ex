defmodule SynapsisWeb.MemoryLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents
  import SynapsisWeb.AgentLive.Components

  alias Synapsis.Memory.{Settings, WorkspaceReader}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:cache_invalidation")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Memory",
       active_tab: "workspace",
       agents: Synapsis.AgentConfigs.list(),
       selected_agent: nil,
       workspace_root: nil,
       workspace_files: [],
       workspace_document: nil,
       workspace_loading: false,
       workspace_error: nil,
       host_enabled: Settings.host_enabled?(),
       host_loading: false,
       host_result: nil,
       host_source: nil,
       host_error: nil,
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
        {:noreply,
         socket
         |> reset_react_form("create-memory-form")
         |> assign(show_create: true, active_tab: "knowledge")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ~w(workspace knowledge events checkpoints) do
    {:noreply,
     socket
     |> cancel_async(:host_recall)
     |> assign(
       active_tab: tab,
       host_enabled: Settings.host_enabled?(),
       host_result: nil,
       host_source: nil,
       host_loading: false
     )
     |> load_data()}
  end

  def handle_event("switch_tab", %{"tab" => "host"}, socket) do
    socket =
      socket
      |> cancel_async(:host_recall)
      |> assign(host_result: nil, host_source: nil, host_loading: false, host_error: nil)

    if Settings.host_enabled?(),
      do: {:noreply, assign(socket, active_tab: "host", host_enabled: true)},
      else: {:noreply, assign(socket, active_tab: "workspace", host_enabled: false)}
  end

  def handle_event("select_agent", %{"agent" => name}, socket) do
    case Enum.find(Synapsis.AgentConfigs.list(), &(&1.name == name)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Select a configured agent")}

      _ ->
        root =
          name
          |> Synapsis.Agent.Resolver.resolve()
          |> Map.fetch!(:workspace_path)
          |> Path.expand()

        {:noreply,
         socket
         |> cancel_async(:workspace_list)
         |> cancel_async(:workspace_read)
         |> assign(selected_agent: name, workspace_root: root, workspace_document: nil)
         |> load_workspace()}
    end
  end

  def handle_event("refresh_workspace", _params, socket) do
    {:noreply,
     socket |> cancel_async(:workspace_list) |> cancel_async(:workspace_read) |> load_workspace()}
  end

  def handle_event("read_workspace", %{"path" => path} = params, socket) do
    root = socket.assigns.workspace_root

    from =
      case Integer.parse(params["from"] || "1") do
        {value, ""} when value > 0 -> value
        _ -> 1
      end

    if root && Enum.any?(socket.assigns.workspace_files, &(&1.path == path)) do
      {:noreply,
       socket
       |> cancel_async(:workspace_read)
       |> assign(workspace_loading: true, workspace_error: nil)
       |> start_async(:workspace_read, fn ->
         WorkspaceReader.read(root, path, from: from, lines: 120)
       end)}
    else
      {:noreply, put_flash(socket, :error, "Select a listed workspace memory file")}
    end
  end

  def handle_event("recall_host", %{"query" => query}, socket) do
    case Settings.host_source() do
      {:ok, source} ->
        {:noreply,
         socket
         |> cancel_async(:host_recall)
         |> assign(host_loading: true, host_error: nil, host_result: nil, host_source: source)
         |> start_async(:host_recall, fn -> Synapsis.Memory.recall_host(query, source: source) end)}

      {:error, reason} ->
        {:noreply,
         socket
         |> cancel_async(:host_recall)
         |> assign(
           active_tab: "workspace",
           host_enabled: false,
           host_result: nil,
           host_source: nil,
           host_error: reason,
           host_loading: false
         )}
    end
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
    {:noreply, socket |> reset_react_form("create-memory-form") |> assign(show_create: false)}
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
         |> reset_react_form("create-memory-form")
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

  @impl true
  def handle_async(:workspace_list, {:ok, {:ok, result}}, socket) do
    {:noreply, assign(socket, workspace_files: result.files, workspace_loading: false)}
  end

  def handle_async(:workspace_read, {:ok, {:ok, document}}, socket) do
    {:noreply, assign(socket, workspace_document: document, workspace_loading: false)}
  end

  def handle_async(name, result, socket) when name in [:workspace_list, :workspace_read] do
    reason =
      case result do
        {:ok, {:error, reason}} when is_atom(reason) -> reason
        _ -> :unavailable
      end

    {:noreply, assign(socket, workspace_error: reason, workspace_loading: false)}
  end

  def handle_async(:host_recall, {:ok, {:ok, result}}, socket) do
    if Settings.host_source() == {:ok, socket.assigns.host_source},
      do: {:noreply, assign(socket, host_result: result, host_loading: false)},
      else:
        {:noreply,
         assign(socket,
           host_result: nil,
           host_loading: false,
           host_enabled: Settings.host_enabled?(),
           host_error: :config_changed
         )}
  end

  def handle_async(:host_recall, result, socket) do
    reason =
      case result do
        {:ok, {:error, reason}} when is_atom(reason) -> reason
        _ -> :unavailable
      end

    {:noreply, assign(socket, host_result: nil, host_error: reason, host_loading: false)}
  end

  defp load_workspace(%{assigns: %{workspace_root: nil}} = socket), do: socket

  defp load_workspace(socket) do
    root = socket.assigns.workspace_root

    socket
    |> assign(
      workspace_loading: true,
      workspace_error: nil,
      workspace_files: [],
      workspace_document: nil
    )
    |> start_async(:workspace_list, fn -> WorkspaceReader.list(root) end)
  end

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
    <.agent_shell active={:memory}>
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/agent/agents"}>Agent</:crumb>
        <:crumb>Memory</:crumb>
      </.breadcrumb>

      <%!-- Tab navigation --%>
      <div class="flex flex-wrap gap-2 mb-4">
        <.dm_btn
          variant={if @active_tab == "workspace", do: "primary", else: "ghost"}
          size="sm"
          phx-click="switch_tab"
          phx-value-tab="workspace"
        >
          Workspace Markdown
        </.dm_btn>
        <.dm_btn
          :if={@host_enabled}
          variant={if @active_tab == "host", do: "primary", else: "ghost"}
          size="sm"
          phx-click="switch_tab"
          phx-value-tab="host"
        >
          Host agent
        </.dm_btn>
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

      <%= if @active_tab == "workspace" do %>
        <.dm_card variant="bordered" class="mb-4">
          <:title>Workspace Markdown</:title>
          <p class="text-sm text-on-surface-variant mb-3">
            Read MEMORY.md and memory/**/*.md from a configured agent workspace.
          </p>
          <.form for={%{}} id="memory-agent-form" phx-change="select_agent">
            <label for="memory-agent" class="label">Agent</label>
            <select id="memory-agent" name="agent" class="select w-full" value={@selected_agent || ""}>
              <option value="">Select an agent</option>
              <option
                :for={agent <- @agents}
                value={agent.name}
                selected={agent.name == @selected_agent}
              >
                {agent.label || agent.name}
              </option>
            </select>
          </.form>
          <p :if={@agents == []} class="text-sm mt-3">Configure an agent to view workspace memory.</p>
          <%= if @selected_agent do %>
            <div class="flex items-center justify-between gap-2 mt-3">
              <span class="text-sm text-on-surface-variant break-all">{@workspace_root}</span>
              <.dm_btn variant="ghost" size="sm" phx-click="refresh_workspace">Refresh</.dm_btn>
            </div>
            <p :if={@workspace_loading} role="status" class="mt-3">Loading workspace memory…</p>
            <p :if={@workspace_error == :unavailable} role="alert" class="mt-3">
              Workspace is unavailable or has not been initialized. Run an agent session or check its workspace configuration.
            </p>
            <p :if={@workspace_error && @workspace_error != :unavailable} role="alert" class="mt-3">
              Workspace memory could not be read ({@workspace_error}).
            </p>
            <p :if={!@workspace_loading && !@workspace_error && @workspace_files == []} class="mt-3">
              No workspace memory files yet.
            </p>
            <div id="workspace-memory-files" class="space-y-2 mt-3">
              <div :for={file <- @workspace_files} class="flex items-center gap-3">
                <.dm_btn
                  variant="ghost"
                  size="sm"
                  phx-click="read_workspace"
                  phx-value-path={file.path}
                >
                  {file.path}
                </.dm_btn>
                <span class="text-xs text-on-surface-variant">{file.size} bytes</span>
              </div>
            </div>
            <%= if @workspace_document do %>
              <article id="workspace-memory-content" class="mt-4">
                <h3 class="font-semibold">{@workspace_document.path}</h3>
                <p class="text-xs text-on-surface-variant">
                  Lines {@workspace_document.from}–{@workspace_document.to}
                </p>
                <pre class="overflow-auto whitespace-pre-wrap break-words text-sm bg-surface-container-high p-3 mt-2"><code :for={{line, number} <- Enum.with_index(Enum.take(String.split(@workspace_document.content, "\n"), max(@workspace_document.to - @workspace_document.from + 1, 0)), @workspace_document.from)}><span class="text-on-surface-variant select-none">{number}  </span>{line}{"\n"}</code></pre>
                <.dm_btn
                  :if={@workspace_document.next_from}
                  variant="ghost"
                  size="sm"
                  phx-click="read_workspace"
                  phx-value-path={@workspace_document.path}
                  phx-value-from={@workspace_document.next_from}
                >
                  Next lines
                </.dm_btn>
                <p :if={@workspace_document.truncated} class="text-xs text-on-surface-variant">
                  This is a bounded excerpt.
                </p>
                <p
                  :if={@workspace_document.notice}
                  role="note"
                  class="text-sm text-on-surface-variant"
                >
                  {@workspace_document.notice}
                </p>
              </article>
            <% end %>
          <% end %>
        </.dm_card>
      <% end %>

      <%= if @active_tab == "host" && @host_enabled do %>
        <.dm_card variant="bordered">
          <:title>Backplane host agent memory</:title>
          <p class="text-sm text-on-surface-variant mb-3">
            Search memory available to the host account. Agent ID selects a host route. Results carry host record IDs, separate from workspace file references.
          </p>
          <.form for={%{}} id="host-memory-query" phx-submit="recall_host">
            <label for="host-memory-query-text" class="label">Recall query</label>
            <.dm_input id="host-memory-query-text" name="query" value="" required maxlength="2048" />
            <.dm_btn type="submit" variant="primary" class="mt-2" disabled={@host_loading}>
              Recall
            </.dm_btn>
          </.form>
          <p :if={@host_loading} role="status" class="mt-3">Recalling host memory…</p>
          <p :if={@host_error} role="alert" class="mt-3">Host recall failed ({@host_error}).</p>
          <%= if @host_result do %>
            <div id="host-memory-state" class="text-sm mt-3 space-y-1">
              <p>Mode: {@host_result.mode} · Authority: {@host_result.authority}</p>
              <p>Consistency: {@host_result.consistency} · Stale: {to_string(@host_result.stale)}</p>
              <p>Source: {@host_result.source.id} · {@host_result.source.endpoint}</p>
            </div>
            <p :if={@host_result.hits == []} class="mt-3">No matching host memories.</p>
            <article
              :for={hit <- @host_result.hits}
              class="border border-outline-variant rounded p-3 mt-3"
            >
              <p class="text-xs text-on-surface-variant">Host record: {hit.memory_id}</p>
              <p class="whitespace-pre-wrap text-sm mt-1">{hit.content}</p>
            </article>
          <% end %>
        </.dm_card>
      <% end %>

      <%!-- Knowledge tab --%>
      <%= if @active_tab == "knowledge" do %>
        <div class="mb-4 flex flex-wrap gap-2 items-center">
          <.dm_select
            id="memory-scope-filter"
            name="scope"
            value={@scope_filter}
            options={[
              {"all", "All Scopes"},
              {"shared", "Shared"},
              {"agent", "Agent"}
            ]}
            size="sm"
            phx-change="filter_scope"
          />

          <.dm_select
            id="memory-kind-filter"
            name="kind"
            value={@kind_filter}
            options={[
              {"all", "All Kinds"},
              {"fact", "Fact"},
              {"decision", "Decision"},
              {"lesson", "Lesson"},
              {"preference", "Preference"},
              {"pattern", "Pattern"},
              {"warning", "Warning"}
            ]}
            size="sm"
            phx-change="filter_kind"
          />

          <.dm_select
            id="memory-source-filter"
            name="source"
            value={@source_filter}
            options={[
              {"all", "All Sources"},
              {"human", "Human"},
              {"agent", "Agent"},
              {"summarizer", "Summarizer"}
            ]}
            size="sm"
            phx-change="filter_source"
          />

          <div class="flex-1" />

          <.dm_btn variant="primary" size="sm" phx-click="show_create">
            <.dm_mdi name="plus" /> New Memory
          </.dm_btn>
        </div>

        <%!-- Create form --%>
        <%= if @show_create do %>
          <.dm_card variant="bordered" class="mb-4">
            <:title>New Memory</:title>
            <.react_form
              for={@create_form}
              id="create-memory-form"
              values={Map.put(@create_form.params, "scope", "agent")}
              draft={react_form_draft(assigns, "create-memory-form")}
              phx-submit="create_memory"
            >
              <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 --%>
              <div class="grid grid-cols-2 gap-4 mb-4">
                <div>
                  <.dm_react_field
                    name="scope"
                    type="select"
                    label="Scope"
                    options={[%{value: "shared", label: "Shared"}, %{value: "agent", label: "Agent"}]}
                  />
                </div>
                <div>
                  <.dm_react_field
                    name="kind"
                    type="select"
                    label="Kind"
                    options={[
                      %{value: "fact", label: "Fact"},
                      %{value: "decision", label: "Decision"},
                      %{value: "lesson", label: "Lesson"},
                      %{value: "preference", label: "Preference"},
                      %{value: "pattern", label: "Pattern"},
                      %{value: "warning", label: "Warning"}
                    ]}
                  />
                </div>
              </div>
              <div class="mb-4">
                <label class="label text-on-surface-variant text-sm">Title</label>
                <.dm_input name="title" value="" placeholder="Short title (~10 words)" required />
              </div>
              <div class="mb-4">
                <label class="label text-on-surface-variant text-sm">Summary</label>
                <.dm_textarea
                  name="summary"
                  value=""
                  placeholder="1-3 sentences"
                  rows={3}
                  required
                />
              </div>
              <div class="mb-4">
                <label class="label text-on-surface-variant text-sm">Tags (comma separated)</label>
                <.dm_input name="tags" value="" placeholder="tag1, tag2, tag3" />
              </div>
              <div class="flex gap-2 justify-end">
                <.dm_btn type="button" variant="ghost" phx-click="cancel_create">Cancel</.dm_btn>
                <.dm_btn variant="secondary" type="submit">Save</.dm_btn>
              </div>
            </.react_form>
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
                        navigate={~p"/agent/memory/#{memory.id}"}
                        class="font-semibold text-on-surface hover:text-primary"
                      >
                        {memory.title}
                      </.dm_link>
                      <.dm_badge size="xs" variant={kind_color(memory.kind)}>
                        {memory.kind}
                      </.dm_badge>
                      <.dm_badge size="xs" variant={scope_color(memory.scope)}>
                        {memory.scope}
                      </.dm_badge>
                      <.dm_badge size="xs" variant={source_color(memory.source)}>
                        {memory.source}
                      </.dm_badge>
                    </div>
                    <p class="text-on-surface-variant text-sm">{memory.summary}</p>
                    <%= if memory.tags != [] do %>
                      <div class="flex gap-1 mt-1 flex-wrap">
                        <%= for tag <- memory.tags do %>
                          <span class="text-xs bg-surface-container-high text-on-surface-variant px-1.5 py-0.5 rounded">
                            {tag}
                          </span>
                        <% end %>
                      </div>
                    <% end %>
                    <div class="flex gap-3 mt-1 text-xs text-on-surface-variant">
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
          <.dm_select
            id="memory-event-type-filter"
            name="type"
            value={@events_type_filter}
            options={[
              {"all", "All Types"},
              {"tool_called", "Tool Called"},
              {"tool_succeeded", "Tool Succeeded"},
              {"tool_failed", "Tool Failed"},
              {"message_added", "Message Added"},
              {"task_completed", "Task Completed"},
              {"task_failed", "Task Failed"},
              {"memory_promoted", "Memory Promoted"},
              {"memory_updated", "Memory Updated"}
            ]}
            size="sm"
            phx-change="filter_event_type"
          />
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
    </.agent_shell>
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
  defp scope_color("agent"), do: "secondary"
  defp scope_color(_), do: "ghost"

  defp source_color("human"), do: "success"
  defp source_color("agent"), do: "info"
  defp source_color("summarizer"), do: "warning"
  defp source_color(_), do: "ghost"
end
