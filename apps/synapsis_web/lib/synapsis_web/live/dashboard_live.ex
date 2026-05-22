defmodule SynapsisWeb.DashboardLive do
  @moduledoc "Main dashboard listing enabled agents and their sessions."
  use SynapsisWeb, :live_view
  require Logger

  alias Synapsis.{AgentConfigs, Sessions}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, agents: [], session_counts: %{}, total_sessions: 0)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    agents = enabled_agents()
    session_counts = Sessions.count_by_agent_names(Enum.map(agents, & &1.name))
    total_sessions = session_counts |> Map.values() |> Enum.sum()

    {:noreply,
     assign(socket,
       page_title: "Dashboard",
       agents: agents,
       session_counts: session_counts,
       total_sessions: total_sessions
     )}
  end

  @impl true
  def handle_event("create_session", %{"agent" => agent_name}, socket) do
    agent_config = Synapsis.Agent.Resolver.resolve(agent_name)
    provider = agent_config.provider || "anthropic"
    model = agent_config.model || Synapsis.Providers.default_model(provider)

    case Sessions.create(agent_name, %{provider: provider, model: model, agent: agent_name}) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/assistant/#{agent_name}/sessions/#{session.id}")}

      {:error, reason} ->
        Logger.warning("dashboard_session_create_failed",
          agent: agent_name,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full max-w-6xl mx-auto p-6 min-h-0">
      <div class="flex items-center justify-between gap-4 mb-4 shrink-0">
        <div>
          <h1 class="text-2xl font-bold">Dashboard</h1>
          <p class="text-sm text-on-surface-variant mt-1">Enabled agents</p>
        </div>
        <.dm_link navigate={~p"/agent/agents"}>
          <.dm_btn variant="ghost" size="sm">
            <.dm_mdi name="cog-outline" class="w-4 h-4" /> Manage
          </.dm_btn>
        </.dm_link>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 mb-4 shrink-0">
        <.stat_card
          icon="robot-outline"
          value={to_string(length(@agents))}
          label="Enabled agents"
          color="primary"
        />
        <.stat_card
          icon="chat-processing-outline"
          value={to_string(@total_sessions)}
          label="Agent sessions"
          color="secondary"
        />
      </div>

      <.empty_state
        :if={@agents == []}
        icon="robot-off-outline"
        title="No enabled agents"
        description="Enable an agent to start sessions."
      >
        <:action>
          <.dm_link navigate={~p"/agent/agents"}>
            <.dm_btn variant="primary" size="sm">Open Agents</.dm_btn>
          </.dm_link>
        </:action>
      </.empty_state>

      <div :if={@agents != []} class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4 min-h-0">
        <.dm_card
          :for={agent <- @agents}
          variant="bordered"
          class="min-h-48 flex flex-col hover:border-primary/40 transition-colors"
        >
          <div class="flex items-start gap-3">
            <div class="w-10 h-10 rounded bg-primary/10 flex items-center justify-center shrink-0">
              <.dm_mdi name={agent.icon || "robot-outline"} class="w-6 h-6 text-primary" />
            </div>
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <h2 class="font-semibold truncate">{agent.label || agent.name}</h2>
                <.dm_badge variant="primary" outline size="sm">
                  {Map.get(@session_counts, agent.name, 0)}
                </.dm_badge>
              </div>
              <p class="text-xs text-on-surface-variant truncate">{agent.name}</p>
            </div>
          </div>

          <p class="text-sm text-on-surface-variant mt-3 line-clamp-3 flex-1">
            {agent.description || "Agent workspace"}
          </p>

          <div class="flex items-center gap-2 mt-4">
            <.dm_link navigate={~p"/assistant/#{agent.name}/sessions"} class="flex-1">
              <.dm_btn variant="secondary" size="sm" class="w-full">
                <.dm_mdi name="message-text-outline" class="w-4 h-4" /> Sessions
              </.dm_btn>
            </.dm_link>
            <.dm_btn
              variant="primary"
              size="sm"
              phx-click="create_session"
              phx-value-agent={agent.name}
            >
              <.dm_mdi name="plus" class="w-4 h-4" /> New
            </.dm_btn>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp enabled_agents do
    case AgentConfigs.list_enabled() do
      [] ->
        Enum.map(AgentConfigs.default_attrs(), fn attrs ->
          struct(AgentConfigLite, Map.take(attrs, [:name, :label, :icon, :description]))
        end)

      agents ->
        agents
    end
  end

  defmodule AgentConfigLite do
    defstruct [:name, :label, :icon, :description]
  end
end
