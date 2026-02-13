defmodule SynapsisWeb.SettingsLive do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Settings")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <h1 class="text-2xl font-bold mb-6">Settings</h1>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.link
            navigate={~p"/settings/providers"}
            class="bg-gray-900 rounded-lg p-6 border border-gray-800 hover:border-gray-700 block"
          >
            <h2 class="text-lg font-semibold mb-1">Providers</h2>
            <p class="text-sm text-gray-500">Manage LLM provider configurations and API keys.</p>
          </.link>

          <.link
            navigate={~p"/settings/memory"}
            class="bg-gray-900 rounded-lg p-6 border border-gray-800 hover:border-gray-700 block"
          >
            <h2 class="text-lg font-semibold mb-1">Memory</h2>
            <p class="text-sm text-gray-500">Manage persistent memory entries across scopes.</p>
          </.link>

          <.link
            navigate={~p"/settings/skills"}
            class="bg-gray-900 rounded-lg p-6 border border-gray-800 hover:border-gray-700 block"
          >
            <h2 class="text-lg font-semibold mb-1">Skills</h2>
            <p class="text-sm text-gray-500">
              Create and edit skill definitions with custom prompts.
            </p>
          </.link>

          <.link
            navigate={~p"/settings/mcp"}
            class="bg-gray-900 rounded-lg p-6 border border-gray-800 hover:border-gray-700 block"
          >
            <h2 class="text-lg font-semibold mb-1">MCP Servers</h2>
            <p class="text-sm text-gray-500">Configure Model Context Protocol server connections.</p>
          </.link>

          <.link
            navigate={~p"/settings/lsp"}
            class="bg-gray-900 rounded-lg p-6 border border-gray-800 hover:border-gray-700 block"
          >
            <h2 class="text-lg font-semibold mb-1">LSP Servers</h2>
            <p class="text-sm text-gray-500">Configure Language Server Protocol integrations.</p>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
