defmodule SynapsisWeb.SettingsLive do
  @moduledoc "Application settings page for user preferences and configuration."
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Settings")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex max-w-6xl mx-auto p-6 gap-6">
      <.settings_sidebar current_path="/settings" />
      <div class="flex-1">
        <h1 class="text-2xl font-bold mb-6">Settings</h1>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.dm_card variant="bordered">
            <:title>
              <.dm_mdi name="theme-light-dark" class="w-5 h-5 inline mr-2" />Theme
            </:title>
            <div class="flex items-center justify-between gap-4" data-testid="settings-theme-switcher">
              <p class="text-sm text-on-surface-variant">
                Choose the interface theme.
              </p>
              <.dm_theme_switcher />
            </div>
          </.dm_card>

          <.dm_link navigate={~p"/settings/providers"}>
            <.dm_card variant="bordered">
              <:title>
                <.dm_mdi name="cloud" class="w-5 h-5 inline mr-2" />Providers
              </:title>
              <p class="text-sm text-on-surface-variant">
                Manage LLM provider configurations and API keys.
              </p>
            </.dm_card>
          </.dm_link>

          <.dm_link navigate={~p"/settings/models"}>
            <.dm_card variant="bordered">
              <:title>
                <.dm_mdi name="tune" class="w-5 h-5 inline mr-2" />Default Model
              </:title>
              <p class="text-sm text-on-surface-variant">
                View default, fast, and expert model tiers per provider.
              </p>
            </.dm_card>
          </.dm_link>

          <.dm_link navigate={~p"/settings/memory"}>
            <.dm_card variant="bordered">
              <:title>
                <.dm_mdi name="brain" class="w-5 h-5 inline mr-2" />Memory
              </:title>
              <p class="text-sm text-on-surface-variant">
                Manage persistent memory entries across scopes.
              </p>
            </.dm_card>
          </.dm_link>

          <.dm_link navigate={~p"/settings/lsp"}>
            <.dm_card variant="bordered">
              <:title>
                <.dm_mdi name="code-braces" class="w-5 h-5 inline mr-2" />LSP Servers
              </:title>
              <p class="text-sm text-on-surface-variant">
                Configure Language Server Protocol integrations.
              </p>
            </.dm_card>
          </.dm_link>
        </div>
      </div>
    </div>
    """
  end
end
