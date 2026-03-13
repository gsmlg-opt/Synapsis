defmodule SynapsisWeb.AssistantLive.Setting do
  @moduledoc "Settings page for a named assistant (agent profile)."
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    agent_config = Synapsis.Agent.Resolver.resolve(name)

    providers =
      case Synapsis.Providers.list(enabled: true) do
        {:ok, list} -> list
        list when is_list(list) -> list
        _ -> []
      end

    {:ok,
     assign(socket,
       page_title: "#{String.capitalize(name)} Settings",
       assistant_name: name,
       agent_config: agent_config,
       providers: providers
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-6">
      <div class="flex items-center gap-3 mb-6">
        <.dm_link
          navigate={~p"/assistant/#{@assistant_name}/sessions"}
          class="text-base-content/50 hover:text-base-content"
        >
          <.dm_mdi name="chevron-left" class="w-5 h-5" />
        </.dm_link>
        <h1 class="text-2xl font-bold">{String.capitalize(@assistant_name)} Settings</h1>
      </div>

      <%!-- Agent Configuration --%>
      <.dm_card variant="bordered" class="mb-4">
        <:title>Agent Configuration</:title>
        <div class="space-y-4">
          <.readonly_field label="Name" value={@agent_config.name} />
          <.readonly_field label="Model Tier" value={to_string(@agent_config.model_tier)} />
          <.readonly_field label="Reasoning Effort" value={@agent_config.reasoning_effort} />
          <.readonly_field label="Max Tokens" value={to_string(@agent_config.max_tokens)} />
          <.readonly_field label="Read Only" value={to_string(@agent_config.read_only)} />
        </div>
      </.dm_card>

      <%!-- System Prompt --%>
      <.dm_card variant="bordered" class="mb-4">
        <:title>System Prompt</:title>
        <pre class="text-sm text-base-content/70 whitespace-pre-wrap bg-base-200 rounded-lg p-3 max-h-64 overflow-y-auto">{@agent_config.system_prompt}</pre>
      </.dm_card>

      <%!-- Tools --%>
      <.dm_card variant="bordered" class="mb-4">
        <:title>Enabled Tools</:title>
        <div class="flex flex-wrap gap-2">
          <.dm_badge :for={tool <- @agent_config.tools} color="ghost" size="sm">
            {tool}
          </.dm_badge>
        </div>
      </.dm_card>

      <%!-- Provider Override --%>
      <.dm_card variant="bordered" class="mb-4">
        <:title>Provider / Model</:title>
        <div class="space-y-3">
          <div>
            <label class="text-xs text-base-content/60">Provider</label>
            <div class="text-sm text-base-content">
              {@agent_config.provider || "Default (from global config)"}
            </div>
          </div>
          <div>
            <label class="text-xs text-base-content/60">Model</label>
            <div class="text-sm text-base-content">
              {@agent_config.model || "Default (from provider)"}
            </div>
          </div>
        </div>
        <:action>
          <div class="text-xs text-base-content/40">
            Configure in
            <.dm_link navigate={~p"/settings"} class="text-primary hover:underline">
              Settings
            </.dm_link>
            or project <code>.opencode.json</code>
          </div>
        </:action>
      </.dm_card>
    </div>
    """
  end
end
