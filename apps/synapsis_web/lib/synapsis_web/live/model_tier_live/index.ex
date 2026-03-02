defmodule SynapsisWeb.ModelTierLive.Index do
  use SynapsisWeb, :live_view

  @tiers [
    %{
      name: "default",
      description: "Standard tier used by the build agent for everyday coding tasks."
    },
    %{
      name: "fast",
      description: "Lightweight tier optimized for speed — used for auditing and quick lookups."
    },
    %{
      name: "expert",
      description:
        "Most capable tier used by the plan agent for reasoning-heavy analysis and planning."
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, tiers: @tiers, page_title: "Default Model")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">Default Model</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">Default Model</h1>

        <p class="text-sm text-gray-400 mb-4">
          Each agent is assigned a model tier. The tier determines which model is used based on the session's provider.
        </p>

        <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-gray-800 text-gray-400">
                <th class="text-left px-4 py-3 font-medium">Tier</th>
                <th class="text-left px-4 py-3 font-medium">Description</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={tier <- @tiers}
                class="border-b border-gray-800 last:border-b-0 hover:bg-gray-800/50"
              >
                <td class="px-4 py-3 font-mono font-medium text-gray-200">{tier.name}</td>
                <td class="px-4 py-3 text-gray-400">{tier.description}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
