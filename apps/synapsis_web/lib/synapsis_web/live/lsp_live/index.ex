defmodule SynapsisWeb.LSPLive.Index do
  use SynapsisWeb, :live_view

  alias Synapsis.{Repo, PluginConfig}
  import Ecto.Query, only: [from: 2]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, configs: [], page_title: "LSP Servers")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    configs = list_configs()

    {:noreply,
     apply_action(socket, socket.assigns.live_action, params) |> assign(configs: configs)}
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
      SynapsisPlugin.LSP.Presets.all()
      |> Enum.find(&(&1.name == name))

    {:noreply, assign(socket, selected_preset: preset)}
  end

  def handle_event("back_to_presets", _params, socket) do
    {:noreply, assign(socket, selected_preset: nil)}
  end

  def handle_event("create_config", params, socket) do
    preset = socket.assigns.selected_preset

    attrs = %{
      type: "lsp",
      name: preset.name,
      command: params["command"] || preset.command,
      args: preset.args,
      auto_start: params["auto_start"] == "true"
    }

    case Repo.insert(PluginConfig.changeset(%PluginConfig{}, attrs)) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(configs: list_configs(), show_form: false, selected_preset: nil)
         |> put_flash(:info, "LSP server added")
         |> push_navigate(to: ~p"/settings/lsp")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add LSP server")}
    end
  end

  def handle_event("delete_config", %{"id" => id}, socket) do
    case Repo.get(PluginConfig, id) do
      nil -> :ok
      config -> Repo.delete(config)
    end

    {:noreply, assign(socket, configs: list_configs())}
  end

  defp list_configs do
    Repo.all(from(p in PluginConfig, where: p.type == "lsp", order_by: [asc: p.name]))
  end

  @impl true
  def render(assigns) do
    presets = SynapsisPlugin.LSP.Presets.all()
    configured = Enum.map(assigns.configs, & &1.name)

    assigns =
      assign(assigns,
        presets: presets,
        configured_names: configured
      )

    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-5xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">LSP Servers</span>
        </div>

        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">LSP Servers</h1>
          <.link
            :if={!@show_form}
            navigate={~p"/settings/lsp/new"}
            class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + Add LSP Server
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
                <h2 class="text-lg font-semibold">Add {@selected_preset.name} LSP</h2>
              </div>
              <form phx-submit="create_config" class="space-y-3">
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Language</label>
                  <div class="bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700">
                    {@selected_preset.name}
                  </div>
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Command</label>
                  <input
                    type="text"
                    name="command"
                    value={@selected_preset.command}
                    readonly
                    class="w-full bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700"
                  />
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Args</label>
                  <div class="bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700">
                    {Enum.join(@selected_preset.args, " ")}
                  </div>
                </div>
                <div>
                  <label class="flex items-center gap-2">
                    <input type="hidden" name="auto_start" value="false" />
                    <input
                      type="checkbox"
                      name="auto_start"
                      value="true"
                      class="rounded bg-gray-800 border-gray-700"
                    />
                    <span class="text-sm">Auto-start</span>
                  </label>
                </div>
                <button
                  type="submit"
                  class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
                >
                  Add LSP Server
                </button>
              </form>
            </div>
          <% else %>
            <div class="mb-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="text-lg font-semibold">Select a Language Server</h2>
                <.link
                  navigate={~p"/settings/lsp"}
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
                  disabled={preset.name in @configured_names}
                  class={[
                    "w-full text-left rounded-lg p-4 border transition-colors",
                    if(preset.name in @configured_names,
                      do:
                        "bg-gray-900/50 border-gray-800 text-gray-600 cursor-not-allowed opacity-50",
                      else:
                        "bg-gray-900 border-gray-800 hover:border-blue-500 hover:bg-gray-800 cursor-pointer"
                    )
                  ]}
                >
                  <div class="font-medium">{preset.name}</div>
                  <div class="text-xs text-gray-500 mt-1">{preset.command}</div>
                  <div :if={preset.name in @configured_names} class="text-xs text-gray-600 mt-1">
                    Already configured
                  </div>
                </button>
              </div>
            </div>
          <% end %>
        <% end %>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <div
            :for={config <- @configs}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800"
          >
            <div class="flex justify-between items-start mb-2">
              <.link
                navigate={~p"/settings/lsp/#{config.id}"}
                class="font-medium hover:text-blue-400 transition-colors"
              >
                {config.name}
              </.link>
              <button
                phx-click="delete_config"
                phx-value-id={config.id}
                data-confirm="Delete this LSP server?"
                class="text-gray-600 hover:text-red-400 text-sm ml-2"
              >
                Delete
              </button>
            </div>
            <div class="text-xs text-gray-500">{config.command}</div>
            <div :if={config.args != []} class="text-xs text-gray-600 mt-1">
              {Enum.join(config.args, " ")}
            </div>
            <div class="mt-2">
              <span
                :if={config.auto_start}
                class="inline-block text-xs px-2 py-0.5 rounded bg-green-900/50 text-green-400"
              >
                Auto-start
              </span>
              <span
                :if={!config.auto_start}
                class="inline-block text-xs px-2 py-0.5 rounded bg-gray-800 text-gray-500"
              >
                Manual
              </span>
            </div>
          </div>
        </div>

        <div :if={@configs == [] && !@show_form} class="text-center text-gray-600 py-12">
          No LSP servers configured. Click "+ Add LSP Server" to get started.
        </div>
      </div>
    </div>
    """
  end
end
