defmodule SynapsisWeb.AgentLive.Components do
  @moduledoc "Shared Agent module layout components."
  use SynapsisWeb, :html

  attr :active, :atom, required: true
  slot :inner_block, required: true

  def agent_shell(assigns) do
    ~H"""
    <div class="flex min-h-full flex-col md:flex-row">
      <nav
        id="agent-mobile-nav"
        aria-label="Agent navigation"
        class="flex gap-1 overflow-x-auto border-b border-outline-variant bg-secondary px-3 py-2 md:hidden"
      >
        <.mobile_nav_link active={@active} item={:daemon} path="/agent/daemon" icon="server-network">
          Daemon
        </.mobile_nav_link>
        <.mobile_nav_link
          active={@active}
          item={:agents}
          path={~p"/agent/agents"}
          icon="robot-outline"
        >
          Agents
        </.mobile_nav_link>
        <.mobile_nav_link active={@active} item={:tools} path={~p"/agent/tools"} icon="tools">
          Tools
        </.mobile_nav_link>
        <.mobile_nav_link
          active={@active}
          item={:skills}
          path={~p"/agent/skills"}
          icon="lightning-bolt"
        >
          Skills
        </.mobile_nav_link>
      </nav>

      <aside class="hidden md:block w-64 shrink-0 border-r border-outline-variant bg-secondary text-secondary-content px-5 py-6">
        <.dm_left_menu active={active_path(@active)} size="lg" class="app-left-menu">
          <:title>Agent</:title>
          <:menu>
            <.dm_link navigate="/agent/daemon" class={nav_item_class(@active, :daemon)}>
              <.dm_mdi name="server-network" class="w-5 h-5 shrink-0" /> Daemon
            </.dm_link>
          </:menu>
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

      <main class="min-w-0 flex-1 p-4 sm:p-6">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :active, :atom, required: true
  attr :item, :atom, required: true
  attr :path, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp mobile_nav_link(assigns) do
    ~H"""
    <.dm_link
      navigate={@path}
      aria-current={@active == @item && "page"}
      class={[
        "flex shrink-0 items-center gap-1.5 rounded-md px-3 py-2 text-sm font-medium text-secondary-content",
        @active == @item && "bg-primary text-primary-content"
      ]}
    >
      <.dm_mdi name={@icon} class="h-4 w-4 shrink-0" />
      {render_slot(@inner_block)}
    </.dm_link>
    """
  end

  defp active_path(:daemon), do: "/agent/daemon"
  defp active_path(:agents), do: ~p"/agent/agents"
  defp active_path(:tools), do: ~p"/agent/tools"
  defp active_path(:skills), do: ~p"/agent/skills"

  defp nav_item_class(active, item) do
    [
      "app-left-menu-item",
      active == item && "app-left-menu-item-active"
    ]
  end
end
