defmodule SynapsisWeb.ProviderLive.Index do
  use SynapsisWeb, :live_view

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
    assign(socket, show_form: true)
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_form: false)
  end

  @impl true
  def handle_event("create_provider", params, socket) do
    attrs = %{
      name: params["name"],
      type: params["type"],
      base_url: params["base_url"],
      api_key_encrypted: params["api_key"]
    }

    case Synapsis.Providers.create(attrs) do
      {:ok, _provider} ->
        {:ok, providers} = Synapsis.Providers.list()

        {:noreply,
         socket
         |> assign(providers: providers, show_form: false)
         |> put_flash(:info, "Provider created")}

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
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">Providers</span>
        </div>

        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">Providers</h1>
          <.link
            navigate={~p"/settings/providers/new"}
            class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + Add Provider
          </.link>
        </div>

        <.flash_group flash={@flash} />

        <div :if={@show_form} class="mb-6 bg-gray-900 rounded-lg p-4 border border-gray-800">
          <form phx-submit="create_provider" class="space-y-3">
            <div class="grid grid-cols-2 gap-3">
              <input
                type="text"
                name="name"
                placeholder="Name (e.g., anthropic)"
                required
                class="bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
              <select
                name="type"
                required
                class="bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              >
                <option value="anthropic">Anthropic</option>
                <option value="openai">OpenAI</option>
                <option value="openai_compat">OpenAI Compatible</option>
                <option value="google">Google</option>
                <option value="groq">Groq</option>
                <option value="openrouter">OpenRouter</option>
                <option value="deepseek">DeepSeek</option>
                <option value="local">Local (Ollama etc.)</option>
              </select>
            </div>
            <input
              type="text"
              name="base_url"
              placeholder="Base URL (optional, for OpenAI-compat)"
              class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <input
              type="password"
              name="api_key"
              placeholder="API Key"
              class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              Create Provider
            </button>
          </form>
        </div>

        <div class="space-y-2">
          <div
            :for={provider <- @providers}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800 flex justify-between items-center"
          >
            <.link navigate={~p"/settings/providers/#{provider.id}"} class="flex-1">
              <div class="font-medium">{provider.name}</div>
              <div class="text-xs text-gray-500 mt-1">
                {provider.type}
                <span :if={provider.base_url}>{"| #{provider.base_url}"}</span>
                <span :if={provider.enabled} class="text-green-500">| Enabled</span>
                <span :if={!provider.enabled} class="text-red-500">| Disabled</span>
              </div>
            </.link>
            <button
              phx-click="delete_provider"
              phx-value-id={provider.id}
              data-confirm="Delete this provider?"
              class="text-gray-600 hover:text-red-400 text-sm"
            >
              Delete
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
