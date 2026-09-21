defmodule SynapsisWeb.SettingsLive do
  @moduledoc "Appearance settings for the application."
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Appearance")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_layout current_path="/settings" content_class="max-w-4xl">
      <h1 class="text-3xl font-bold mb-3">Appearance</h1>
      <p id="theme-description" class="text-lg text-on-surface-variant mb-8">
        Choose system theme preference: automatic, light, or dark.
      </p>

      <div
        id="appearance-theme"
        phx-hook="ThemeSwitcher"
        class="theme-controller theme-controller-lg w-full"
        role="radiogroup"
        aria-label="Theme"
        aria-describedby="theme-description"
      >
        <input
          id="theme-auto"
          type="radio"
          name="theme-mode"
          value="auto"
          class="theme-controller-item"
          checked
        />
        <label for="theme-auto" class="theme-controller-label">
          <.dm_mdi name="monitor" class="w-6 h-6" aria-hidden="true" /> Auto
        </label>
        <input
          id="theme-light"
          type="radio"
          name="theme-mode"
          value="sunshine"
          class="theme-controller-item"
        />
        <label for="theme-light" class="theme-controller-label">
          <.dm_mdi name="white-balance-sunny" class="w-6 h-6" aria-hidden="true" /> Light
        </label>
        <input
          id="theme-dark"
          type="radio"
          name="theme-mode"
          value="moonlight"
          class="theme-controller-item"
        />
        <label for="theme-dark" class="theme-controller-label">
          <.dm_mdi name="weather-night" class="w-6 h-6" aria-hidden="true" /> Dark
        </label>
      </div>
    </.settings_layout>
    """
  end
end
