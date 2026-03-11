defmodule SynapsisWeb.MCPLive.Show do
  use SynapsisWeb, :live_view

  alias Synapsis.{Repo, PluginConfig}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Repo.get(PluginConfig, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "MCP server not found")
         |> push_navigate(to: ~p"/settings/mcp")}

      %PluginConfig{type: "mcp"} = config ->
        {:ok, assign(socket, config: config, page_title: config.name)}

      _other ->
        {:ok,
         socket
         |> put_flash(:error, "Not an MCP configuration")
         |> push_navigate(to: ~p"/settings/mcp")}
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
      auto_start: params["auto_start"] == "true"
    }

    changeset = PluginConfig.changeset(socket.assigns.config, attrs)

    case Repo.update(changeset) do
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
    <div class="max-w-4xl mx-auto p-6">
      <.dm_breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/mcp"}>MCP Servers</:crumb>
        <:crumb>{@config.name}</:crumb>
      </.dm_breadcrumb>

      <h1 class="text-2xl font-bold mb-6">{@config.name}</h1>

      <.dm_card variant="bordered">
        <.dm_form for={%{}} phx-submit="update_config">
          <.dm_select
            name="transport"
            label="Transport"
            options={[{"stdio", "stdio"}, {"sse", "SSE"}]}
            value={@config.transport}
          />

          <.dm_input
            type="text"
            name="command"
            value={@config.command}
            label="Command"
          />

          <.dm_textarea
            name="args"
            rows={3}
            label="Arguments (one per line)"
            value={format_args(@config.args)}
          />

          <.dm_input
            type="text"
            name="url"
            value={@config.url}
            label="URL"
          />

          <.dm_textarea
            name="env"
            rows={4}
            placeholder="GITHUB_TOKEN=ghp_xxx\nAPI_KEY=sk-xxx"
            label="Environment Variables (KEY=VALUE, one per line)"
            value={format_env(@config.env)}
          />

          <div>
            <input type="hidden" name="auto_start" value="false" />
            <.dm_checkbox
              name="auto_start"
              value="true"
              checked={@config.auto_start}
              label="Auto-start on startup"
            />
          </div>

          <.dm_btn type="submit" variant="primary">
            Save Changes
          </.dm_btn>
        </.dm_form>
      </.dm_card>
    </div>
    """
  end
end
