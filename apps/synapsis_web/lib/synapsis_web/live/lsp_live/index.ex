defmodule SynapsisWeb.LSPLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    configs = list_configs()
    {:ok, assign(socket, configs: configs, page_title: "LSP Servers")}
  end

  @impl true
  def handle_event("create_config", params, socket) do
    attrs = %{
      language: params["language"],
      command: params["command"],
      auto_start: params["auto_start"] == "true"
    }

    case Synapsis.Repo.insert(Synapsis.LSPConfig.changeset(%Synapsis.LSPConfig{}, attrs)) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(configs: list_configs())
         |> put_flash(:info, "LSP server added")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add LSP server")}
    end
  end

  def handle_event("delete_config", %{"id" => id}, socket) do
    case Synapsis.Repo.get(Synapsis.LSPConfig, id) do
      nil -> :ok
      config -> Synapsis.Repo.delete(config)
    end

    {:noreply, assign(socket, configs: list_configs())}
  end

  defp list_configs do
    import Ecto.Query
    Synapsis.Repo.all(from(l in Synapsis.LSPConfig, order_by: [asc: l.language]))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">LSP Servers</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">LSP Servers</h1>

        <.flash_group flash={@flash} />

        <div class="mb-6 bg-gray-900 rounded-lg p-4 border border-gray-800">
          <form phx-submit="create_config" class="flex gap-2">
            <input
              type="text"
              name="language"
              placeholder="Language (e.g., elixir)"
              required
              class="flex-1 bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <input
              type="text"
              name="command"
              placeholder="Command (e.g., elixir-ls)"
              required
              class="flex-1 bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              Add
            </button>
          </form>
        </div>

        <div class="space-y-2">
          <div
            :for={config <- @configs}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800 flex justify-between items-center"
          >
            <.link navigate={~p"/settings/lsp/#{config.id}"} class="flex-1">
              <div class="font-medium">{config.language}</div>
              <div class="text-xs text-gray-500 mt-1">{config.command}</div>
            </.link>
            <button
              phx-click="delete_config"
              phx-value-id={config.id}
              data-confirm="Delete this LSP server?"
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
