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
        {:ok,
         assign(socket,
           config: config,
           page_title: config.name,
           form_values: form_values_from_config(config)
         )}

      _other ->
        {:ok,
         socket
         |> put_flash(:error, "Not an MCP configuration")
         |> push_navigate(to: ~p"/settings/mcp")}
    end
  end

  @impl true
  def handle_event("change_config_form", params, socket) do
    {:noreply, assign(socket, form_values: Map.drop(params, ["_target"]))}
  end

  def handle_event("update_config", params, socket) do
    transport = params["transport"] || socket.assigns.config.transport

    attrs = %{
      command: command_for_transport(transport, params),
      args: args_for_transport(transport, params),
      url: url_for_transport(transport, params),
      transport: transport,
      env: env_for_transport(transport, params),
      settings: settings_for_transport(transport, params),
      auto_start: params["auto_start"] == "true"
    }

    changeset = PluginConfig.changeset(socket.assigns.config, attrs)

    case Repo.update(changeset) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(config: config, form_values: form_values_from_config(config))
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

  defp parse_headers(nil), do: %{}
  defp parse_headers(""), do: %{}

  defp parse_headers(str) when is_binary(str) do
    str
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          name = String.trim(name)

          if name == "" do
            acc
          else
            Map.put(acc, name, String.trim(value))
          end

        _ ->
          acc
      end
    end)
  end

  defp command_for_transport("stdio", params), do: params["command"]
  defp command_for_transport(_transport, _params), do: ""

  defp args_for_transport("stdio", params), do: parse_args(params["args"])
  defp args_for_transport(_transport, _params), do: []

  defp url_for_transport(transport, params) when transport in ["http", "sse"], do: params["url"]
  defp url_for_transport(_transport, _params), do: nil

  defp env_for_transport("stdio", params), do: parse_env(params["env"])
  defp env_for_transport(_transport, _params), do: %{}

  defp settings_for_transport(transport, params) when transport in ["http", "sse"] do
    headers = parse_headers(params["headers"])
    if headers == %{}, do: %{}, else: %{"headers" => headers}
  end

  defp settings_for_transport(_transport, _params), do: %{}

  defp format_args(args) when is_list(args), do: Enum.join(args, "\n")
  defp format_args(_), do: ""

  defp format_env(env) when is_map(env) do
    env |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_env(_), do: ""

  defp format_headers(settings) when is_map(settings) do
    settings
    |> Map.get("headers", %{})
    |> case do
      headers when is_map(headers) ->
        headers |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

      _ ->
        ""
    end
  end

  defp format_headers(_settings), do: ""

  defp form_values_from_config(%PluginConfig{} = config) do
    %{
      "transport" => config.transport || "stdio",
      "command" => config.command || "",
      "args" => format_args(config.args),
      "url" => config.url || "",
      "env" => format_env(config.env),
      "headers" => format_headers(config.settings)
    }
  end

  defp form_value(form, key, default \\ "") when is_map(form) do
    Map.get(form, key, default) || default
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_layout current_path="/settings/mcp" content_class="max-w-4xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/mcp"}>MCP Servers</:crumb>
        <:crumb>{@config.name}</:crumb>
      </.breadcrumb>

      <h1 class="text-2xl font-bold mb-6">{@config.name}</h1>

      <.dm_card variant="bordered">
        <.dm_form for={%{}} phx-submit="update_config" phx-change="change_config_form">
          <.dm_select
            name="transport"
            label="Transport"
            options={[{"stdio", "stdio"}, {"http", "HTTP"}]}
            value={form_value(@form_values, "transport", "stdio")}
          />

          <div :if={form_value(@form_values, "transport", "stdio") == "stdio"}>
            <.dm_input
              type="text"
              name="command"
              value={form_value(@form_values, "command")}
              label="Command"
            />

            <.dm_textarea
              name="args"
              rows={3}
              label="Arguments (one per line)"
              value={form_value(@form_values, "args")}
            />

            <.dm_textarea
              name="env"
              rows={4}
              placeholder="GITHUB_TOKEN=ghp_xxx\nAPI_KEY=sk-xxx"
              label="Environment Variables (KEY=VALUE, one per line)"
              value={form_value(@form_values, "env")}
            />
          </div>

          <div :if={form_value(@form_values, "transport", "stdio") in ["http", "sse"]}>
            <.dm_input
              type="text"
              name="url"
              value={form_value(@form_values, "url")}
              label="URL"
            />

            <.dm_textarea
              name="headers"
              rows={4}
              placeholder="Authorization: Bearer token"
              label="Headers (Name: Value, one per line)"
              value={form_value(@form_values, "headers")}
            />
          </div>

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
    </.settings_layout>
    """
  end
end
