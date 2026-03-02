defmodule SynapsisWeb.ProviderLive.Index do
  use SynapsisWeb, :live_view

  @custom_presets [
    %{name: "", type: "openai", base_url: "", label: "OpenAI Compatible", custom: true},
    %{name: "", type: "anthropic", base_url: "", label: "Anthropic Compatible", custom: true}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, providers: [], page_title: "Providers")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:ok, providers} = Synapsis.Providers.list()

    {:noreply,
     apply_action(socket, socket.assigns.live_action, params) |> assign(providers: providers)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, show_form: true, selected_preset: nil)
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_form: false, selected_preset: nil)
  end

  @impl true
  def handle_event("select_preset", %{"name" => name}, socket) do
    preset =
      Synapsis.Providers.preset_providers()
      |> Enum.find(&(&1.name == name))

    {:noreply, assign(socket, selected_preset: Map.put(preset, :custom, false))}
  end

  def handle_event("select_custom", %{"type" => type}, socket) do
    preset = Enum.find(@custom_presets, &(&1.type == type))
    {:noreply, assign(socket, selected_preset: preset)}
  end

  def handle_event("back_to_presets", _params, socket) do
    {:noreply, assign(socket, selected_preset: nil)}
  end

  def handle_event("create_provider", params, socket) do
    preset = socket.assigns.selected_preset

    attrs = %{
      name: params["name"],
      type: preset.type,
      base_url: if(preset.custom, do: params["base_url"], else: preset.base_url),
      api_key_encrypted: params["api_key"]
    }

    case Synapsis.Providers.create(attrs) do
      {:ok, _provider} ->
        {:ok, providers} = Synapsis.Providers.list()

        {:noreply,
         socket
         |> assign(providers: providers, show_form: false, selected_preset: nil)
         |> put_flash(:info, "Provider created")
         |> push_navigate(to: ~p"/settings/providers")}

      {:error, %Ecto.Changeset{errors: errors}} ->
        msg =
          case Keyword.get(errors, :name) do
            {"has already been taken", _} -> "Name already taken"
            _ -> "Failed to create provider"
          end

        {:noreply, put_flash(socket, :error, msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create provider")}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    case Synapsis.Providers.delete(id) do
      {:ok, _} ->
        providers = Enum.reject(socket.assigns.providers, &(&1.id == id))
        {:noreply, assign(socket, providers: providers)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete provider")}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        presets: Synapsis.Providers.preset_providers(),
        custom_presets: @custom_presets
      )

    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-5xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">Providers</span>
        </div>

        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">Providers</h1>
          <.link
            :if={!@show_form}
            navigate={~p"/settings/providers/new"}
            class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + Add Provider
          </.link>
        </div>

        <.flash_group flash={@flash} />

        <%= if @show_form do %>
          <%= if @selected_preset do %>
            <div class="mb-6 bg-gray-900 rounded-lg p-6 border border-gray-800">
              <div class="flex items-center gap-3 mb-4">
                <button
                  phx-click="back_to_presets"
                  class="text-gray-400 hover:text-gray-200 text-sm"
                >
                  &larr; Back
                </button>
                <h2 class="text-lg font-semibold">
                  <%= if @selected_preset.custom do %>
                    New {@selected_preset.label}
                  <% else %>
                    Add {@selected_preset.name}
                  <% end %>
                </h2>
              </div>
              <form phx-submit="create_provider" class="space-y-3">
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Name</label>
                  <input
                    type="text"
                    name="name"
                    value={@selected_preset.name}
                    placeholder="Unique name for this provider"
                    required
                    class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
                  />
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Type</label>
                  <div class="bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700">
                    {@selected_preset.type}
                  </div>
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Base URL</label>
                  <%= if @selected_preset.custom do %>
                    <input
                      type="text"
                      name="base_url"
                      placeholder="https://api.example.com"
                      required
                      class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
                    />
                  <% else %>
                    <div class="bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700">
                      {@selected_preset.base_url}
                    </div>
                  <% end %>
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">API Key</label>
                  <input
                    type="password"
                    name="api_key"
                    placeholder="Enter API key"
                    required
                    class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
                  />
                </div>
                <button
                  type="submit"
                  class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
                >
                  Add Provider
                </button>
              </form>
            </div>
          <% else %>
            <div class="mb-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="text-lg font-semibold">Select a Provider</h2>
                <.link
                  navigate={~p"/settings/providers"}
                  class="text-gray-400 hover:text-gray-200 text-sm"
                >
                  Cancel
                </.link>
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                <button
                  :for={preset <- @presets}
                  phx-click="select_preset"
                  phx-value-name={preset.name}
                  class="w-full text-left bg-gray-900 rounded-lg p-4 border border-gray-800 hover:border-blue-500 hover:bg-gray-800 transition-colors cursor-pointer"
                >
                  <div class="font-medium">{preset.name}</div>
                  <div class="text-xs text-gray-500 mt-1">{preset.type}</div>
                </button>
              </div>

              <h3 class="text-sm font-semibold text-gray-400 mt-6 mb-3">Custom</h3>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                <button
                  :for={custom <- @custom_presets}
                  phx-click="select_custom"
                  phx-value-type={custom.type}
                  class="w-full text-left bg-gray-900 rounded-lg p-4 border border-dashed border-gray-700 hover:border-blue-500 hover:bg-gray-800 transition-colors cursor-pointer"
                >
                  <div class="font-medium">{custom.label}</div>
                  <div class="text-xs text-gray-500 mt-1">Custom base URL</div>
                </button>
              </div>
            </div>
          <% end %>
        <% end %>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <div
            :for={provider <- @providers}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800"
          >
            <div class="flex justify-between items-start mb-2">
              <.link
                navigate={~p"/settings/providers/#{provider.id}"}
                class="font-medium hover:text-blue-400 transition-colors"
              >
                {provider.name}
              </.link>
              <button
                phx-click="delete_provider"
                phx-value-id={provider.id}
                data-confirm="Delete this provider?"
                class="text-gray-600 hover:text-red-400 text-sm ml-2"
              >
                Delete
              </button>
            </div>
            <div class="text-xs text-gray-500">{provider.type}</div>
            <div :if={provider.base_url} class="text-xs text-gray-600 mt-1 truncate">
              {provider.base_url}
            </div>
            <div class="mt-2">
              <span
                :if={provider.enabled}
                class="inline-block text-xs px-2 py-0.5 rounded bg-green-900/50 text-green-400"
              >
                Enabled
              </span>
              <span
                :if={!provider.enabled}
                class="inline-block text-xs px-2 py-0.5 rounded bg-red-900/50 text-red-400"
              >
                Disabled
              </span>
            </div>
          </div>
        </div>

        <div :if={@providers == [] && !@show_form} class="text-center text-gray-600 py-12">
          No providers configured. Click "+ Add Provider" to get started.
        </div>
      </div>
    </div>
    """
  end
end
