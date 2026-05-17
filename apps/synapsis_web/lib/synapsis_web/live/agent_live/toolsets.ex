defmodule SynapsisWeb.AgentLive.Toolsets do
  @moduledoc "Agent module page for managing named toolsets."
  use SynapsisWeb, :live_view

  import SynapsisWeb.AgentLive.Components

  alias Synapsis.{Toolset, Toolsets}

  @tool_categories [
    {:filesystem, "Files"},
    {:search, "Search"},
    {:execution, "Runtime"},
    {:web, "Web"},
    {:planning, "Planning"},
    {:orchestration, "Orchestration"},
    {:interaction, "Interaction"},
    {:session, "Sessions"},
    {:memory, "Memory"},
    {:workspace, "Workspace"},
    {:communication, "Communication"},
    {:workflow, "Workflow"},
    {:swarm, "Swarm"},
    {:notebook, "Notebook"},
    {:computer, "Computer"},
    {:uncategorized, "Other"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Toolsets",
       toolset: nil,
       toolsets: [],
       selected_tool_names: [],
       available_tools: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign_common()
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_toolset", %{"toolset" => attrs} = params, socket) do
    tool_names = params |> Map.get("tool_names", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    attrs = Map.put(attrs, "tool_names", tool_names)

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
    selected_tool_names = selected_tool_names(params)

    {:noreply,
     assign(socket,
       toolset: preview_toolset(socket.assigns.toolset, toolset_attrs),
       selected_tool_names: selected_tool_names
     )}
  end

  def handle_event("select_all_tools", _params, socket) do
    tool_names = Enum.map(socket.assigns.available_tools, & &1.name)
    selected_tool_names = merge_tool_names(socket.assigns.selected_tool_names, tool_names)

    {:noreply, assign(socket, selected_tool_names: selected_tool_names)}
  end

  def handle_event("select_tool_group", %{"category" => category}, socket) do
    tool_names =
      socket.assigns.available_tools
      |> Enum.filter(&(to_string(&1.category) == category))
      |> Enum.map(& &1.name)

    selected_tool_names = merge_tool_names(socket.assigns.selected_tool_names, tool_names)

    {:noreply, assign(socket, selected_tool_names: selected_tool_names)}
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

        <.toolset_form
          :if={@live_action in [:new, :edit]}
          toolset={@toolset}
          available_tools={@available_tools}
          selected_tool_names={@selected_tool_names}
        />

        <div :if={@live_action == :index} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.dm_card :for={toolset <- @toolsets} variant="bordered">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <h2 class="font-semibold">{toolset.name}</h2>
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

  defp toolset_form(assigns) do
    available_names = Enum.map(assigns.available_tools, & &1.name)
    unavailable_names = assigns.selected_tool_names -- available_names
    tool_groups = available_tool_groups(assigns.available_tools)

    assigns =
      assigns
      |> assign(:unavailable_names, unavailable_names)
      |> assign(:tool_groups, tool_groups)

    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>{if @toolset.id, do: "Edit Toolset", else: "New Toolset"}</:title>

      <.dm_form
        for={%{}}
        as={:toolset}
        phx-submit="save_toolset"
        phx-change="change_toolset_form"
        class="space-y-4"
      >
        <.dm_input type="text" name="toolset[name]" value={@toolset.name} required label="Name" />
        <.dm_textarea
          name="toolset[description]"
          value={@toolset.description}
          rows={2}
          label="Description"
          resize="none"
        />

        <div>
          <div class="mb-2 flex items-center justify-between gap-3">
            <div class="text-sm font-medium">Tools</div>
            <.dm_btn type="button" variant="ghost" size="xs" phx-click="select_all_tools">
              Select all
            </.dm_btn>
          </div>
          <div class="space-y-4">
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
                    type="checkbox"
                    name="tool_names[]"
                    value={tool.name}
                    checked={tool.name in @selected_tool_names}
                  />
                  <span class="min-w-0">
                    <span class="font-mono text-xs">{tool.name}</span>
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
      </.dm_form>
    </.dm_card>
    """
  end

  defp assign_common(socket) do
    assign(socket,
      toolsets: Toolsets.list(),
      available_tools: available_tools()
    )
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Toolsets", toolset: nil, selected_tool_names: [])
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Toolset",
      toolset: %Toolset{tool_names: []},
      selected_tool_names: []
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Toolsets.get(id) do
      %Toolset{} = toolset ->
        assign(socket,
          page_title: "Edit Toolset",
          toolset: toolset,
          selected_tool_names: toolset.tool_names || []
        )

      nil ->
        socket
        |> put_flash(:error, "Toolset not found")
        |> push_navigate(to: ~p"/agent/tools")
    end
  end

  defp selected_tool_names(params) do
    params
    |> Map.get("tool_names", [])
    |> List.wrap()
    |> Enum.reject(&(&1 == ""))
  end

  defp preview_toolset(%Toolset{} = toolset, attrs) do
    %{
      toolset
      | name: Map.get(attrs, "name", toolset.name),
        description: Map.get(attrs, "description", toolset.description)
    }
  end

  defp merge_tool_names(existing, additions) do
    (List.wrap(existing) ++ List.wrap(additions))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp available_tools do
    category_lookup = tool_category_lookup()

    Synapsis.Tool.Registry.list()
    |> Enum.map(fn tool ->
      category = Map.get(category_lookup, tool.name, :uncategorized)

      %{
        name: tool.name,
        description: tool.description || "",
        category: category,
        category_label: category_label(category),
        source: if(String.starts_with?(tool.name, "mcp:"), do: "mcp", else: "built-in")
      }
    end)
    |> Enum.sort_by(&{category_index(&1.category), &1.name})
  rescue
    ArgumentError -> []
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

  defp tool_category_lookup do
    Enum.reduce(@tool_categories, %{}, fn {category, _label}, acc ->
      category
      |> Synapsis.Tool.Registry.list_by_category()
      |> Enum.reduce(acc, fn tool, inner -> Map.put(inner, tool.name, category) end)
    end)
  end

  defp category_label(category) do
    @tool_categories
    |> Enum.find_value("Other", fn
      {^category, label} -> label
      _ -> nil
    end)
  end

  defp category_index(category) do
    Enum.find_index(@tool_categories, fn {known, _label} -> known == category end) ||
      length(@tool_categories)
  end
end
