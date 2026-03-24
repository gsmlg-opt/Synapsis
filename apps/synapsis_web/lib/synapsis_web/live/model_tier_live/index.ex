defmodule SynapsisWeb.ModelTierLive.Index do
  use SynapsisWeb, :live_view

  @tiers [
    %{
      name: "default",
      description: "Standard tier used by the build agent for everyday coding tasks.",
      color: "primary"
    },
    %{
      name: "fast",
      description: "Lightweight tier optimized for speed — used for auditing and quick lookups.",
      color: "warning"
    },
    %{
      name: "expert",
      description:
        "Most capable tier used by the plan agent for reasoning-heavy analysis and planning.",
      color: "accent"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, tiers: @tiers, page_title: "Default Model")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Default Model</:crumb>
      </.breadcrumb>

      <h1 class="text-2xl font-bold mb-6">Default Model</h1>

      <p class="text-sm text-base-content/60 mb-4">
        Each agent is assigned a model tier. The tier determines which model is used based on the session's provider.
      </p>

      <.dm_table data={@tiers}>
        <:col :let={tier} label="Tier">
          <.dm_badge variant={tier.color} size="sm">
            {tier.name}
          </.dm_badge>
        </:col>
        <:col :let={tier} label="Description">
          <span class="text-base-content/60">{tier.description}</span>
        </:col>
      </.dm_table>
    </div>
    """
  end
end
