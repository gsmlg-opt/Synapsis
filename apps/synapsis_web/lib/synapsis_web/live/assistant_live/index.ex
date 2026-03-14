defmodule SynapsisWeb.AssistantLive.Index do
  @moduledoc "Lists available assistants (agent profiles)."
  use SynapsisWeb, :live_view

  @default_assistants [
    %{
      name: "build",
      label: "Build",
      icon: "hammer-wrench",
      description:
        "Full-featured coding assistant with file editing, shell execution, and search tools."
    },
    %{
      name: "plan",
      label: "Plan",
      icon: "file-document-outline",
      description:
        "Read-only planning assistant for analyzing code and creating implementation plans."
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    config = Synapsis.Config.resolve("__global__")
    custom_agents = get_custom_agents(config)

    {:ok,
     assign(socket,
       page_title: "Assistants",
       assistants: @default_assistants ++ custom_agents
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
                <.dm_badge color="ghost" size="sm">{assistant.name}</.dm_badge>
                <.dm_mdi name="chevron-right" class="w-4 h-4 text-base-content/30" />
              </div>
            </:action>
          </.dm_card>
        </.dm_link>
      </div>
    </div>
    """
  end

  defp get_custom_agents(config) do
    case config["agents"] do
      agents when is_map(agents) ->
        agents
        |> Enum.reject(fn {name, _} -> name in ~w(build plan) end)
        |> Enum.map(fn {name, _agent_config} ->
          %{
            name: name,
            label: String.capitalize(name),
            icon: "robot-outline",
            description: "Custom agent: #{name}"
          }
        end)

      _ ->
        []
    end
  end
end
