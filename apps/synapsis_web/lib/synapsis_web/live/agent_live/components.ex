defmodule SynapsisWeb.AgentLive.Components do
  @moduledoc "Shared Agent module layout components."
  use SynapsisWeb, :html

  attr :active, :atom, required: true
  slot :inner_block, required: true

  def agent_shell(assigns) do
    ~H"""
    <div class="flex min-h-full">
      <aside class="hidden md:block w-64 shrink-0 border-r border-outline-variant bg-secondary text-secondary-content px-5 py-6">
        <.dm_left_menu active={active_path(@active)} size="lg" class="agent-left-menu">
          <:title>Agent</:title>
          <:menu>
            <.dm_link navigate={~p"/agent/agents"} class={nav_item_class(@active, :agents)}>
              <.dm_mdi name="robot-outline" class="w-5 h-5 shrink-0" /> Agents
            </.dm_link>
          </:menu>
          <:menu>
            <.dm_link navigate={~p"/agent/tools"} class={nav_item_class(@active, :tools)}>
              <.dm_mdi name="tools" class="w-5 h-5 shrink-0" /> Tools
            </.dm_link>
          </:menu>
          <:menu>
            <.dm_link navigate={~p"/agent/skills"} class={nav_item_class(@active, :skills)}>
              <.dm_mdi name="lightning-bolt" class="w-5 h-5 shrink-0" /> Skills
            </.dm_link>
          </:menu>
        </.dm_left_menu>
      </aside>

      <main class="flex-1 min-w-0 p-6">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  defp active_path(:agents), do: ~p"/agent/agents"
  defp active_path(:tools), do: ~p"/agent/tools"
  defp active_path(:skills), do: ~p"/agent/skills"

  defp nav_item_class(active, item) do
    [
      "agent-left-menu-item",
      active == item && "agent-left-menu-item-active"
    ]
  end
end
