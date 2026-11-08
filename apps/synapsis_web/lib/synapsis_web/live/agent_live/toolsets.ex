defmodule SynapsisWeb.AgentLive.Toolsets do
  @moduledoc "Agent module page for managing named toolsets."
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  import SynapsisWeb.AgentLive.Components

  alias Synapsis.{Toolset, Toolsets}

  @tool_categories [
    {:filesystem, "Files"},
    {:search, "Search"},
    {:execution, "Runtime"},
    {:web, "Web"},
    {:media, "Media"},
    {:planning, "Planning"},
    {:orchestration, "Orchestration"},
    {:interaction, "Interaction"},
    {:session, "Sessions"},
    {:memory, "Memory"},
    {:communication, "Communication"},
    {:workflow, "Workflow"},
    {:swarm, "Swarm"},
    {:uncategorized, "Other"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_registry")
    end

    {:ok,
     assign(socket,
       page_title: "Toolsets",
       toolset: nil,
       toolsets: [],
       selected_tool_names: [],
       available_tools: [],
       mcp_sources: [],
       selected_source: "built-in",
       selection_revision: 0
     )}
  end

  @impl true
  def handle_info({:tool_registry_changed, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:mcp_source_catalog_changed, _payload}, socket) do
    {:noreply, assign_tool_catalog(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign_common()
      |> apply_action(socket.assigns.live_action, params)
      |> assign_tool_catalog()

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_mcp_tools", _params, socket),
    do: {:noreply, assign_tool_catalog(socket)}

  def handle_event("save_toolset", %{"toolset" => attrs} = params, socket) do
    tool_names =
      selected_tool_names(
        params,
        socket.assigns.selected_tool_names,
        socket.assigns.toolset.tool_contract_version
      )

    attrs =
      attrs
      |> Map.put("tool_names", tool_names)
      |> Map.put("tool_contract_version", socket.assigns.toolset.tool_contract_version)

    result =
      case socket.assigns.live_action do
        :new -> Toolsets.create(attrs)
        :edit -> Toolsets.update(socket.assigns.toolset, attrs)
        _ -> {:error, :unsupported_action}
      end

    case result do
      {:ok, %Toolset{}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Toolset saved")
         |> push_navigate(to: ~p"/agent/tools")}

      {:error, :protected} ->
        {:noreply, put_flash(socket, :error, "Built-in toolsets cannot be changed")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save toolset")}
    end
  end

  def handle_event("change_toolset_form", params, socket) do
    toolset_attrs = Map.get(params, "toolset", %{})

    selected_tool_names =
      selected_tool_names(
        params,
        socket.assigns.selected_tool_names,
        socket.assigns.toolset.tool_contract_version
      )

    {:noreply,
     assign(socket,
       toolset: preview_toolset(socket.assigns.toolset, toolset_attrs),
       selected_tool_names: selected_tool_names
     )}
  end

  def handle_event("select_tool_source", %{"source" => source}, socket) do
    source =
      socket.assigns.mcp_sources
      |> tool_source_options()
      |> Enum.find_value("built-in", fn {value, _label} ->
        if value == source, do: value
      end)

    {:noreply, assign(socket, :selected_source, source)}
  end

  def handle_event(
        event,
        _params,
        %{assigns: %{toolset: %Toolset{tool_contract_version: 0}}} = socket
      )
      when event in ["select_all_tools", "select_tool_group"],
      do: {:noreply, socket}

  def handle_event("select_all_tools", _params, socket) do
    tool_names =
      socket.assigns.available_tools
      |> tools_for_source(socket.assigns.selected_source)
      |> Enum.map(& &1.name)

    selected_tool_names = merge_tool_names(socket.assigns.selected_tool_names, tool_names)

    {:noreply,
     socket
     |> assign(
       selected_tool_names: selected_tool_names,
       selection_revision: socket.assigns.selection_revision + 1
     )
     |> reset_react_form(
       "toolset-form",
       toolset_form_values(socket.assigns.toolset, selected_tool_names)
     )}
  end

  def handle_event("select_tool_group", %{"category" => category}, socket) do
    tool_names =
      socket.assigns.available_tools
      |> tools_for_source(socket.assigns.selected_source)
      |> Enum.filter(&(to_string(&1.category) == category))
      |> Enum.map(& &1.name)

    selected_tool_names = merge_tool_names(socket.assigns.selected_tool_names, tool_names)

    {:noreply,
     socket
     |> assign(
       selected_tool_names: selected_tool_names,
       selection_revision: socket.assigns.selection_revision + 1
     )
     |> reset_react_form(
       "toolset-form",
       toolset_form_values(socket.assigns.toolset, selected_tool_names)
     )}
  end

  def handle_event("delete_toolset", %{"id" => id}, socket) do
    with %Toolset{} = toolset <- Toolsets.get(id),
         {:ok, _} <- Toolsets.delete(toolset) do
      {:noreply, socket |> assign_common() |> put_flash(:info, "Toolset removed")}
    else
      {:error, :protected} ->
        {:noreply, put_flash(socket, :error, "Built-in toolsets cannot be removed")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.agent_shell active={:tools}>
      <div class="max-w-5xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold">Toolsets</h1>
            <p class="text-sm text-on-surface-variant">
              Combine predefined and MCP tools for agents.
            </p>
          </div>
          <.dm_link :if={@live_action == :index} navigate={~p"/agent/tools/new"}>
            <.dm_btn variant="primary" size="sm">
              <.dm_mdi name="plus" class="w-4 h-4" /> New Toolset
            </.dm_btn>
          </.dm_link>
        </div>

        <div :if={@live_action in [:new, :edit]} class="mb-4">
          <.dm_btn type="button" phx-click="refresh_mcp_tools" size="sm">
            Refresh local MCP catalog
          </.dm_btn>
        </div>

        <.toolset_form
          :if={@live_action in [:new, :edit]}
          toolset={@toolset}
          available_tools={@available_tools}
          selected_tool_names={@selected_tool_names}
          mcp_sources={@mcp_sources}
          selected_source={@selected_source}
          selection_revision={@selection_revision}
          draft={react_form_draft(assigns, "toolset-form")}
        />

        <div :if={@live_action == :index} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.dm_card :for={toolset <- @toolsets} variant="bordered">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <h2 class="font-semibold">{toolset.name}</h2>
                  <span class="text-xs text-on-surface-variant">
                    {if toolset.tool_contract_version == 1, do: "Native v1", else: "Legacy v0"}
                  </span>
                  <.dm_badge :if={toolset.is_builtin} variant="primary" size="sm">built-in</.dm_badge>
                </div>
                <p class="text-xs text-on-surface-variant mt-1">{toolset.description}</p>
                <div class="flex flex-wrap gap-1 mt-3">
                  <.dm_badge :for={name <- toolset.tool_names || []} variant="ghost" size="sm">
                    {name}
                  </.dm_badge>
                </div>
              </div>
              <div class="flex items-center gap-1 shrink-0">
                <.dm_link navigate={~p"/agent/tools/#{toolset.id}/edit"}>
                  <.dm_btn variant="ghost" size="xs">
                    <.dm_mdi name="pencil" class="w-3.5 h-3.5" /> Edit
                  </.dm_btn>
                </.dm_link>
                <.dm_btn
                  variant="ghost"
                  size="xs"
                  class="text-error"
                  phx-click="delete_toolset"
                  phx-value-id={toolset.id}
                  confirm="Remove this toolset?"
                >
                  Remove
                </.dm_btn>
              </div>
            </div>
          </.dm_card>
        </div>

        <.empty_state
          :if={@live_action == :index && @toolsets == []}
          icon="tools"
          title="No toolsets"
          description="Create a toolset to assign tools to agents."
        />
      </div>
    </.agent_shell>
    """
  end

  attr :toolset, :map, required: true
  attr :available_tools, :list, required: true
  attr :selected_tool_names, :list, required: true
  attr :mcp_sources, :list, required: true
  attr :selected_source, :string, required: true
  attr :selection_revision, :integer, required: true
  attr :draft, :map, default: nil

  defp toolset_form(assigns) do
    selected_names = Enum.uniq(assigns.selected_tool_names)
    available_names = Enum.map(assigns.available_tools, & &1.name)
    legacy? = assigns.toolset.tool_contract_version == 0

    unavailable_names =
      if legacy?, do: [], else: Enum.reject(selected_names, &(&1 in available_names))

    source_options = tool_source_options(assigns.mcp_sources)
    source_tools = tools_for_source(assigns.available_tools, assigns.selected_source)
    source_names = Enum.map(source_tools, & &1.name)
    tool_groups = available_tool_groups(source_tools)
    selected_source_label = source_label(assigns.selected_source, assigns.mcp_sources)

    assigns =
      assigns
      |> assign(:legacy?, legacy?)
      |> assign(:legacy_names, if(legacy?, do: selected_names, else: []))
      |> assign(
        :draft,
        if(assigns.draft, do: Map.put(assigns.draft, "tool_names", assigns.selected_tool_names))
      )
      |> assign(:unavailable_names, unavailable_names)
      |> assign(:source_options, source_options)
      |> assign(:source_tools, source_tools)
      |> assign(
        :off_source_names,
        if(legacy?,
          do: [],
          else: Enum.reject(selected_names, &(&1 in source_names or &1 in unavailable_names))
        )
      )
      |> assign(:tool_groups, tool_groups)
      |> assign(:selected_source_label, selected_source_label)

    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>{if @toolset.id, do: "Edit Toolset", else: "New Toolset"}</:title>
      <p :if={@toolset.tool_contract_version == 0} class="mb-4 text-sm text-warning">
        Legacy selection · contract v0. Explicit migration required before native runtime use.
        Saving metadata keeps the saved selection and version. Native tools below are a read-only
        preview; create a new native Toolset to select them explicitly.
        <.dm_link navigate={~p"/agent/tools/new"}>New native Toolset</.dm_link>
      </p>
      <p :if={@toolset.tool_contract_version == 1} class="mb-4 text-sm text-on-surface-variant">
        Native contract v1. This catalog describes supported tools; it does not establish runtime
        readiness or grant permission. Saved unavailable selections remain removable.
      </p>

      <.react_form
        for={%{}}
        as={:toolset}
        id="toolset-form"
        values={toolset_form_values(@toolset, @selected_tool_names)}
        draft={@draft}
        structure={[
          @selected_source,
          @available_tools,
          Enum.map(@mcp_sources, &Map.take(&1, [:id, :name, :enabled, :status, :tool_count])),
          @selection_revision
        ]}
        phx-submit="save_toolset"
        phx-change="change_toolset_form"
        class="space-y-4"
      >
        <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 - preserve required and textarea layout attributes. --%>
        <.dm_input type="text" name="toolset[name]" value={@toolset.name} required label="Name" />
        <.dm_textarea
          name="toolset[description]"
          value={@toolset.description}
          rows={2}
          label="Description"
          resize="none"
        />

        <input :for={name <- @off_source_names} type="hidden" name="tool_names[]" value={name} />
        <section
          :if={@legacy?}
          data-tool-category="legacy-selection"
          class="rounded-lg border border-warning/50 bg-surface-container-high p-3"
        >
          <h3 class="text-sm font-semibold mb-2">Saved legacy selection</h3>
          <p class="text-xs text-on-surface-variant mb-3">
            Uncheck a saved name to remove all its occurrences. Other saved names keep their order
            and duplicates, including names also shown in the native preview.
          </p>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
            <label
              :for={name <- @legacy_names}
              class="flex items-start gap-2 rounded border border-warning/50 bg-surface p-2 text-sm"
            >
              <input type="checkbox" name="tool_names[]" value={name} checked />
              <span class="font-mono text-xs break-all">{name}</span>
            </label>
          </div>
          <p :if={@legacy_names == []} class="text-xs text-on-surface-variant">
            No saved legacy names.
          </p>
        </section>
        <div data-testid={if @legacy?, do: "native-catalog-preview", else: "native-catalog"}>
          <p :if={@legacy?} class="text-sm font-medium mb-3">Native catalog · read-only preview</p>
          <div class="mb-3">
            <div class="mb-2 text-sm font-medium">Tool source</div>
            <div class="flex flex-wrap gap-2" data-testid="tool-source-selector">
              <.dm_btn
                :for={{source, label} <- @source_options}
                type="button"
                variant={if(@selected_source == source, do: "primary", else: "ghost")}
                size="sm"
                phx-click="select_tool_source"
                phx-value-source={source}
              >
                {label}
              </.dm_btn>
            </div>
          </div>

          <div class="mb-2 flex items-center justify-between gap-3">
            <div>
              <div class="text-sm font-medium">Tools</div>
              <div class="text-xs text-on-surface-variant">{@selected_source_label}</div>
            </div>
            <.dm_btn
              :if={!@legacy?}
              type="button"
              variant="ghost"
              size="xs"
              phx-click="select_all_tools"
            >
              Select all from source
            </.dm_btn>
          </div>
          <div class="space-y-4">
            <div
              :if={@source_tools == []}
              class="rounded-lg border border-outline-variant bg-surface-container-high p-4 text-sm text-on-surface-variant"
            >
              No tools are present in the local MCP snapshot. Check Settings &gt; MCP Servers.
            </div>

            <section
              :for={{category, label, tools} <- @tool_groups}
              data-tool-category={category}
              class="rounded-lg border border-outline-variant bg-surface-container-high p-3"
            >
              <div class="mb-3 flex items-center justify-between gap-3">
                <div>
                  <h3 class="text-sm font-semibold">{label}</h3>
                  <span class="text-xs text-on-surface-variant">{length(tools)} tools</span>
                </div>
                <.dm_btn
                  :if={!@legacy?}
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="select_tool_group"
                  phx-value-category={category}
                >
                  Select all
                </.dm_btn>
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                <label
                  :for={tool <- tools}
                  class="flex items-start gap-2 rounded border border-outline-variant bg-surface p-2 text-sm"
                >
                  <input
                    :if={!@legacy?}
                    type="checkbox"
                    name="tool_names[]"
                    value={tool.name}
                    checked={tool.name in @selected_tool_names}
                  />
                  <span class="min-w-0">
                    <span class="font-mono text-xs break-all">{tool.name}</span>
                    <span class="block text-xs text-on-surface-variant truncate">
                      {tool.description}
                    </span>
                  </span>
                </label>
              </div>
            </section>

            <section
              :if={@unavailable_names != []}
              data-tool-category="unavailable"
              class="rounded-lg border border-warning/50 bg-surface-container-high p-3"
            >
              <div class="mb-3 flex items-center justify-between gap-3">
                <h3 class="text-sm font-semibold">Unavailable</h3>
                <span class="text-xs text-warning">{length(@unavailable_names)} tools</span>
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                <label
                  :for={name <- @unavailable_names}
                  class="flex items-start gap-2 rounded border border-warning/50 bg-surface p-2 text-sm"
                >
                  <input type="checkbox" name="tool_names[]" value={name} checked />
                  <span class="min-w-0">
                    <span class="font-mono text-xs">{name}</span>
                    <span class="block text-xs text-warning">Unavailable</span>
                  </span>
                </label>
              </div>
            </section>
          </div>
        </div>

        <:actions>
          <.dm_link navigate={~p"/agent/tools"}>
            <.dm_btn type="button" variant="ghost">Cancel</.dm_btn>
          </.dm_link>
          <.dm_btn type="submit" variant="primary">Save Toolset</.dm_btn>
        </:actions>
      </.react_form>
    </.dm_card>
    """
  end

  defp assign_common(socket) do
    assign(socket,
      toolsets: Toolsets.list()
    )
  end

  defp assign_tool_catalog(socket) do
    {mcp_tools, sources} = native_mcp_catalog()
    tools = Synapsis.Agent.Tools.DisplayCatalog.list() ++ mcp_tools
    known_sources = ["built-in" | Enum.map(sources, & &1.id)]

    selected_source =
      if socket.assigns.selected_source in known_sources,
        do: socket.assigns.selected_source,
        else: initial_tool_source(socket.assigns.selected_tool_names, known_sources)

    assign(socket, available_tools: tools, mcp_sources: sources, selected_source: selected_source)
  end

  defp native_mcp_catalog do
    Toolsets.list_mcp_sources()
    |> Enum.map(fn source ->
      snapshot =
        if Synapsis.MCPConfigs.runtime_available?(source),
          do: Synapsis.MCP.runtime_snapshot(source.id),
          else: {:error, :disabled}

      {tools, status} =
        case snapshot do
          {:ok, %{source_id: id, tools: tools}} when id == source.id ->
            {Enum.map(tools, fn tool ->
               %{
                 name: "mcp::#{source.id}::#{tool.raw_name}",
                 description: tool.description || "",
                 category: :uncategorized,
                 source: source.id
               }
             end), :available}

          _ ->
            {[], if(source.enabled, do: :unavailable, else: :disabled)}
        end

      {tools, source |> Map.put(:status, status) |> Map.put(:tool_count, length(tools))}
    end)
    |> Enum.unzip()
    |> then(fn {tools, sources} -> {List.flatten(tools), sources} end)
  end

  defp apply_action(socket, :index, _params) do
    assign(socket,
      page_title: "Toolsets",
      toolset: nil,
      selected_tool_names: [],
      selected_source: "built-in"
    )
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Toolset",
      toolset: %Toolset{tool_names: [], tool_contract_version: 1},
      selected_tool_names: [],
      selected_source: "built-in"
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Toolsets.get(id) do
      %Toolset{} = toolset ->
        assign(socket,
          page_title: "Edit Toolset",
          toolset: toolset,
          selected_tool_names: toolset.tool_names || [],
          selected_source: nil
        )

      nil ->
        socket
        |> put_flash(:error, "Toolset not found")
        |> push_navigate(to: ~p"/agent/tools")
    end
  end

  defp toolset_form_values(toolset, tool_names) do
    %{
      "toolset" => %{"name" => toolset.name || "", "description" => toolset.description || ""},
      "tool_names" => tool_names
    }
  end

  defp selected_tool_names(params, existing, version) do
    submitted =
      params
      |> Map.get("tool_names", [])
      |> List.wrap()
      |> active_tool_names()

    # Native checkboxes submit DOM order and coalesce duplicates. Selection is
    # per name, so retain the saved order and every occurrence still selected.
    retained = Enum.filter(existing, &(&1 in submitted))
    additions = Enum.reject(submitted, &(&1 in existing))
    if version == 0, do: retained, else: retained ++ additions
  end

  defp preview_toolset(%Toolset{} = toolset, attrs) do
    %{
      toolset
      | name: Map.get(attrs, "name", toolset.name),
        description: Map.get(attrs, "description", toolset.description)
    }
  end

  defp merge_tool_names(existing, additions) do
    existing = existing |> List.wrap() |> active_tool_names()

    additions =
      additions
      |> List.wrap()
      |> active_tool_names()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in existing))

    existing ++ additions
  end

  defp active_tool_names(tool_names) do
    Enum.reject(tool_names, &(&1 in [nil, ""]))
  end

  defp tools_for_source(tools, source) do
    Enum.filter(tools, &(&1.source == source))
  end

  defp tool_source_options(mcp_sources) do
    configured =
      Enum.map(mcp_sources, fn source ->
        {source.id, "MCP: #{source.name} · #{source.tool_count} tools · #{source.status}"}
      end)

    [{"built-in", "Built in"} | Enum.sort_by(configured, &elem(&1, 1))]
  end

  defp source_label("built-in", _mcp_sources), do: "Built-in tools"

  defp source_label(source, mcp_sources) do
    case Enum.find(mcp_sources, &(&1.id == source)) do
      nil -> "MCP source: #{source}"
      mcp -> "MCP source: #{mcp.name}"
    end
  end

  defp initial_tool_source(tool_names, known_sources) do
    Enum.find_value(tool_names, "built-in", fn
      "mcp::" <> rest ->
        source = rest |> String.split("::", parts: 2) |> List.first()
        if source in known_sources, do: source

      _ ->
        nil
    end)
  end

  defp available_tool_groups(tools) do
    tools
    |> Enum.group_by(& &1.category)
    |> then(fn grouped ->
      @tool_categories
      |> Enum.map(fn {category, label} ->
        category_tools =
          grouped
          |> Map.get(category, [])
          |> Enum.sort_by(& &1.name)

        {category, label, category_tools}
      end)
      |> Enum.reject(fn {_category, _label, category_tools} -> category_tools == [] end)
    end)
  end
end
