defmodule SynapsisWeb.LSPLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Repo.get(Synapsis.LSPConfig, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "LSP server not found")
         |> push_navigate(to: ~p"/settings/lsp")}

      config ->
        {:ok, assign(socket, config: config, page_title: config.language)}
    end
  end

  @impl true
  def handle_event("update_config", params, socket) do
    attrs = %{
      command: params["command"],
      root_path: params["root_path"],
      auto_start: params["auto_start"] == "true"
    }

    changeset = Synapsis.LSPConfig.changeset(socket.assigns.config, attrs)

    case Synapsis.Repo.update(changeset) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(config: config)
         |> put_flash(:info, "LSP server updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update")}
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
          <.link navigate={~p"/settings/lsp"} class="hover:text-gray-300">LSP Servers</.link>
          <span>/</span>
          <span class="text-gray-300">{@config.language}</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">{@config.language}</h1>

        <.flash_group flash={@flash} />

        <div class="bg-gray-900 rounded-lg p-6 border border-gray-800">
          <form phx-submit="update_config" class="space-y-4">
            <div>
              <label class="block text-sm text-gray-400 mb-1">Command</label>
              <input
                type="text"
                name="command"
                value={@config.command}
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">Root Path</label>
              <input
                type="text"
                name="root_path"
                value={@config.root_path}
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
            </div>

            <div>
              <label class="flex items-center gap-2">
                <input type="hidden" name="auto_start" value="false" />
                <input
                  type="checkbox"
                  name="auto_start"
                  value="true"
                  checked={@config.auto_start}
                  class="rounded bg-gray-800 border-gray-700"
                />
                <span class="text-sm">Auto-start</span>
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
