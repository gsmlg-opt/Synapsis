defmodule SynapsisWeb.AgentLive.Components do
  @moduledoc "Shared Agent module layout components."
  use SynapsisWeb, :html

  attr :active, :atom, required: true
  slot :inner_block, required: true

  def agent_shell(assigns) do
    ~H"""
    <div class="flex min-h-full">
      <aside class="hidden md:block w-56 shrink-0 border-r border-outline-variant bg-secondary text-secondary-content p-4">
        <.dm_left_menu active={active_path(@active)} size="sm">
          <:title>Agent</:title>
          <:menu>
            <.dm_link navigate={~p"/agent/agents"} class="flex items-center gap-2 w-full">
              <.dm_mdi name="robot-outline" class="w-4 h-4" /> Agents
            </.dm_link>
          </:menu>
          <:menu>
            <.dm_link navigate={~p"/agent/tools"} class="flex items-center gap-2 w-full">
              <.dm_mdi name="tools" class="w-4 h-4" /> Tools
            </.dm_link>
          </:menu>
          <:menu>
            <.dm_link navigate={~p"/agent/skills"} class="flex items-center gap-2 w-full">
              <.dm_mdi name="lightning-bolt" class="w-4 h-4" /> Skills
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
end
