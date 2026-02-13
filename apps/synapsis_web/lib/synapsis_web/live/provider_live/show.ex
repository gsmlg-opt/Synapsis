defmodule SynapsisWeb.ProviderLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Providers.get(id) do
      {:ok, provider} ->
        {:ok, assign(socket, provider: provider, page_title: provider.name)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Provider not found")
         |> push_navigate(to: ~p"/settings/providers")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_provider", params, socket) do
    attrs =
      %{
        base_url: params["base_url"],
        enabled: params["enabled"] == "true"
      }
      |> then(fn attrs ->
        if params["api_key"] && params["api_key"] != "",
          do: Map.put(attrs, :api_key_encrypted, params["api_key"]),
          else: attrs
      end)

    case Synapsis.Providers.update(socket.assigns.provider.id, attrs) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> assign(provider: provider)
         |> put_flash(:info, "Provider updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update provider")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <.link navigate={~p"/settings/providers"} class="hover:text-gray-300">Providers</.link>
          <span>/</span>
          <span class="text-gray-300">{@provider.name}</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">{@provider.name}</h1>

        <.flash_group flash={@flash} />

        <div class="bg-gray-900 rounded-lg p-6 border border-gray-800">
          <form phx-submit="update_provider" class="space-y-4">
            <div>
              <label class="block text-sm text-gray-400 mb-1">Type</label>
              <div class="text-gray-200">{@provider.type}</div>
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">Base URL</label>
              <input
                type="text"
                name="base_url"
                value={@provider.base_url}
                placeholder="https://api.example.com/v1"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">API Key</label>
              <input
                type="password"
                name="api_key"
                placeholder="Leave empty to keep current key"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
              <div :if={@provider.api_key_encrypted} class="text-xs text-green-500 mt-1">
                Key is set
              </div>
            </div>

            <div>
              <label class="flex items-center gap-2">
                <input type="hidden" name="enabled" value="false" />
                <input
                  type="checkbox"
                  name="enabled"
                  value="true"
                  checked={@provider.enabled}
                  class="rounded bg-gray-800 border-gray-700"
                />
                <span class="text-sm">Enabled</span>
              </label>
            </div>

            <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              Save Changes
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
