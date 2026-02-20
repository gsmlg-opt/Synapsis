defmodule SynapsisWeb.MCPLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Repo.get(Synapsis.MCPConfig, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "MCP server not found")
         |> push_navigate(to: ~p"/settings/mcp")}

      config ->
        {:ok, assign(socket, config: config, page_title: config.name)}
    end
  end

  @impl true
  def handle_event("update_config", params, socket) do
    attrs = %{
      command: params["command"],
      args: parse_args(params["args"]),
      url: params["url"],
      transport: params["transport"],
      env: parse_env(params["env"]),
      auto_connect: params["auto_connect"] == "true"
    }

    changeset = Synapsis.MCPConfig.changeset(socket.assigns.config, attrs)

    case Synapsis.Repo.update(changeset) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(config: config)
         |> put_flash(:info, "MCP server updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update")}
    end
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

  defp format_args(args) when is_list(args), do: Enum.join(args, "\n")
  defp format_args(_), do: ""

  defp format_env(env) when is_map(env) do
    env |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_env(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <.link navigate={~p"/settings/mcp"} class="hover:text-gray-300">MCP Servers</.link>
          <span>/</span>
          <span class="text-gray-300">{@config.name}</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">{@config.name}</h1>

        <.flash_group flash={@flash} />

        <div class="bg-gray-900 rounded-lg p-6 border border-gray-800">
          <form phx-submit="update_config" class="space-y-4">
            <div>
              <label class="block text-sm text-gray-400 mb-1">Transport</label>
              <select
                name="transport"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              >
                <option value="stdio" selected={@config.transport == "stdio"}>stdio</option>
                <option value="sse" selected={@config.transport == "sse"}>SSE</option>
              </select>
            </div>

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
              <label class="block text-sm text-gray-400 mb-1">Arguments (one per line)</label>
              <textarea
                name="args"
                rows="3"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none font-mono text-sm"
              >{format_args(@config.args)}</textarea>
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">URL</label>
              <input
                type="text"
                name="url"
                value={@config.url}
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">
                Environment Variables (KEY=VALUE, one per line)
              </label>
              <textarea
                name="env"
                rows="4"
                placeholder="GITHUB_TOKEN=ghp_xxx\nAPI_KEY=sk-xxx"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none font-mono text-sm"
              >{format_env(@config.env)}</textarea>
            </div>

            <div>
              <label class="flex items-center gap-2">
                <input type="hidden" name="auto_connect" value="false" />
                <input
                  type="checkbox"
                  name="auto_connect"
                  value="true"
                  checked={@config.auto_connect}
                  class="rounded bg-gray-800 border-gray-700"
                />
                <span class="text-sm">Auto-connect on startup</span>
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
