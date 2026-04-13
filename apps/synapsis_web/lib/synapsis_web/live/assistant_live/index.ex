defmodule SynapsisWeb.AssistantLive.Index do
  @moduledoc "Lists available assistants (agent profiles) from the database."
  use SynapsisWeb, :live_view

  alias Synapsis.AgentConfigs

  @impl true
  def mount(_params, _session, socket) do
    agents = AgentConfigs.list_enabled()

    assistants =
      Enum.map(agents, fn ac ->
        %{
          name: ac.name,
          label: ac.label || String.capitalize(ac.name),
          icon: ac.icon || "robot-outline",
          description: ac.description || "Agent: #{ac.name}"
        }
      end)

    # If no agents in DB yet, show hardcoded defaults
    assistants =
      if assistants == [] do
        [
          %{
            name: "main",
            label: "Main",
            icon: "robot-outline",
            description: "AI coding assistant with full workspace access, tools, and memory."
          }
        ]
      else
        assistants
      end

    {:ok,
     assign(socket,
       page_title: "Assistants",
       assistants: assistants
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Assistants</h1>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <.dm_link
          :for={assistant <- @assistants}
          navigate={~p"/assistant/#{assistant.name}/sessions"}
          class="block"
        >
          <.dm_card variant="bordered" class="hover:border-primary/50 transition-colors h-full">
            <div class="flex items-start gap-3">
              <div class="bg-primary/10 rounded-lg p-2">
                <.dm_mdi name={assistant.icon} class="w-6 h-6 text-primary" />
              </div>
              <div class="flex-1 min-w-0">
                <h3 class="font-medium text-base-content">{assistant.label}</h3>
                <p class="text-xs text-base-content/50 mt-1">{assistant.description}</p>
              </div>
            </div>
            <:action>
              <div class="flex items-center justify-between">
                <.dm_badge variant="ghost" size="sm">{assistant.name}</.dm_badge>
                <.dm_mdi name="chevron-right" class="w-4 h-4 text-base-content/30" />
              </div>
            </:action>
          </.dm_card>
        </.dm_link>
      </div>
    </div>
    """
  end
end
