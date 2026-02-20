defmodule SynapsisWeb.MCPLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    configs = list_configs()
    {:ok, assign(socket, configs: configs, page_title: "MCP Servers")}
  end

  @impl true
  def handle_event("create_config", params, socket) do
    attrs = %{
      name: params["name"],
      transport: params["transport"] || "stdio",
      command: params["command"],
      args: parse_args(params["args"]),
      url: params["url"],
      env: parse_env(params["env"]),
      auto_connect: params["auto_connect"] == "true"
    }

    case Synapsis.Repo.insert(Synapsis.MCPConfig.changeset(%Synapsis.MCPConfig{}, attrs)) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(configs: list_configs())
         |> put_flash(:info, "MCP server added")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add MCP server")}
    end
  end

  def handle_event("delete_config", %{"id" => id}, socket) do
    case Synapsis.Repo.get(Synapsis.MCPConfig, id) do
      nil -> :ok
      config -> Synapsis.Repo.delete(config)
    end

    {:noreply, assign(socket, configs: list_configs())}
  end

  defp list_configs do
    import Ecto.Query
    Synapsis.Repo.all(from(m in Synapsis.MCPConfig, order_by: [asc: m.name]))
  end

  defp parse_args(nil), do: []
  defp parse_args(""), do: []

  defp parse_args(str) when is_binary(str) do
    str |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_env(nil), do: %{}
  defp parse_env(""), do: %{}

  defp parse_env(str) when is_binary(str) do
    str
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">MCP Servers</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">MCP Servers</h1>

        <.flash_group flash={@flash} />

        <div class="mb-6 bg-gray-900 rounded-lg p-4 border border-gray-800">
          <form phx-submit="create_config" class="space-y-3">
            <div class="grid grid-cols-3 gap-3">
              <input
                type="text"
                name="name"
                placeholder="Server name"
                required
                class="bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
              <select
                name="transport"
                class="bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              >
                <option value="stdio">stdio</option>
                <option value="sse">SSE</option>
              </select>
              <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
                Add Server
              </button>
            </div>
            <input
              type="text"
              name="command"
              placeholder="Command (for stdio transport)"
              class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <textarea
              name="args"
              placeholder="Arguments (one per line)"
              rows="2"
              class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none font-mono text-sm"
            ></textarea>
            <input
              type="text"
              name="url"
              placeholder="URL (for SSE transport)"
              class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <textarea
              name="env"
              placeholder="Environment variables (KEY=VALUE, one per line)\ne.g. GITHUB_TOKEN=ghp_xxx"
              rows="3"
              class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none font-mono text-sm"
            ></textarea>
          </form>
        </div>

        <div class="space-y-2">
          <div
            :for={config <- @configs}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800 flex justify-between items-center"
          >
            <.link navigate={~p"/settings/mcp/#{config.id}"} class="flex-1">
              <div class="font-medium">{config.name}</div>
              <div class="text-xs text-gray-500 mt-1">
                {config.transport}
                <span :if={config.command}>{"| #{config.command}"}</span>
                <span :if={config.args != []}>
                  {Enum.join(config.args, " ")}
                </span>
                <span :if={config.url}>{"| #{config.url}"}</span>
                <span :if={map_size(config.env) > 0} class="text-yellow-600">
                  {"| #{map_size(config.env)} env var(s)"}
                </span>
              </div>
            </.link>
            <button
              phx-click="delete_config"
              phx-value-id={config.id}
              data-confirm="Delete this MCP server?"
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
