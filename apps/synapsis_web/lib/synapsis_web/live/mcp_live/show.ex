defmodule SynapsisWeb.MCPLive.Show do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents
  require Logger

  alias Synapsis.{MCPConfig, MCPConfigs}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case MCPConfigs.get(id) do
      %MCPConfig{} = config ->
        if connected?(socket), do: send(self(), :refresh_open_catalog)

        {:ok,
         assign(socket,
           config: config,
           page_title: config.name,
           catalog_loading: false,
           catalog_error: nil,
           form_values: form_values_from_config(config)
         )}

      nil ->
        {:ok,
         socket
         |> put_flash(:error, "MCP server not found")
         |> push_navigate(to: ~p"/settings/mcp")}
    end
  end

  @impl true
  def handle_event("refresh_catalog", _params, %{assigns: %{catalog_loading: true}} = socket),
    do: {:noreply, socket}

  def handle_event("refresh_catalog", _params, socket) do
    id = socket.assigns.config.id

    {:noreply,
     socket
     |> assign(catalog_loading: true, catalog_error: nil)
     |> start_async(:mcp_catalog, fn -> Synapsis.MCP.refresh(id) end)}
  end

  def handle_event("change_config_form", params, socket) do
    {:noreply, assign(socket, form_values: Map.drop(params, ["_target"]))}
  end

  def handle_event("update_config", params, socket) do
    current = socket.assigns.config
    transport = params["transport"] || current.transport
    url = url_for_transport(transport, params)

    attrs = %{
      command: command_for_transport(transport, params),
      args: args_for_transport(transport, params),
      url: url,
      transport: transport,
      env: env_for_transport(transport, params),
      headers: headers_for_transport(transport, params),
      enabled: params["enabled"] == "true",
      config:
        if(current.provider_id && url != current.url,
          do: Map.put(current.config, "provider_url_override", true),
          else: current.config
        )
    }

    case MCPConfigs.update(socket.assigns.config, attrs) do
      {:ok, config} ->
        case persist_source_url(config) do
          :ok ->
            {:noreply, finish_update(socket, config)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "MCP saved but source URL could not be updated")}
        end

      {:error, %Ecto.Changeset{errors: errors}} ->
        message =
          if Keyword.has_key?(errors, :headers) do
            "Invalid headers. Use Name: Value, one per line, without JSON braces."
          else
            "Failed to update"
          end

        {:noreply, put_flash(socket, :error, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update")}
    end
  end

  @impl true
  def handle_info(:refresh_open_catalog, socket) do
    {:noreply,
     socket
     |> assign(catalog_loading: true, catalog_error: nil)
     |> start_async(:mcp_catalog, fn -> Synapsis.MCPSelection.refresh() end)}
  end

  @impl true
  def handle_async(:mcp_catalog, {:ok, outcomes}, socket) when is_map(outcomes) do
    case Map.get(outcomes, socket.assigns.config.id, :ok) do
      :ok ->
        {:noreply, assign(socket, catalog_loading: false, catalog_error: nil)}

      _ ->
        {:noreply,
         assign(socket,
           catalog_loading: false,
           catalog_error:
             "Live tool discovery failed. Tools remain unavailable until refresh succeeds."
         )}
    end
  end

  def handle_async(:mcp_catalog, {:ok, :ok}, socket),
    do: {:noreply, assign(socket, catalog_loading: false, catalog_error: nil)}

  def handle_async(:mcp_catalog, _failure, socket),
    do:
      {:noreply,
       assign(socket,
         catalog_loading: false,
         catalog_error:
           "Live tool discovery failed. Tools remain unavailable until refresh succeeds."
       )}

  defp persist_source_url(%MCPConfig{provider_id: id, config: metadata} = config)
       when is_binary(id) do
    if metadata["provider_url_override"] == true,
      do: do_persist_source_url(metadata["backplane_source_id"], config),
      else: :ok
  end

  defp persist_source_url(config) do
    do_persist_source_url(config.config["backplane_source_id"], config)
  end

  defp do_persist_source_url(source_id, config) do
    case source_id do
      nil ->
        :ok

      source_id ->
        with {:ok, source} <- Synapsis.Backplane.Connection.get(source_id),
             {:ok, _} <-
               Synapsis.Backplane.Connection.update(source, %{
                 connection_options: Map.put(source.connection_options, "mcp_url", config.url)
               }) do
          :ok
        end
    end
  end

  defp finish_update(socket, config) do
    socket =
      socket
      |> assign(config: config, form_values: form_values_from_config(config))
      |> reset_react_form("mcp-config-form", form_values_from_config(config))

    if config.enabled do
      put_flash(socket, :info, "MCP server updated")
    else
      stop_disabled_server(socket, config.name)
    end
  end

  defp stop_disabled_server(socket, name) do
    case Synapsis.MCP.stop(name) do
      :ok ->
        put_flash(socket, :info, "MCP server updated")

      {:error, :not_found} ->
        put_flash(socket, :info, "MCP server updated")

      {:error, reason} ->
        Logger.warning("mcp_disable_stop_failed", name: name, reason: inspect(reason))
        put_flash(socket, :error, "MCP server was disabled but could not be stopped")
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

  defp url_for_transport(transport, params) when transport in ["streamable_http", "sse"],
    do: params["url"]

  defp url_for_transport(_transport, _params), do: nil

  defp env_for_transport("stdio", params), do: parse_env(params["env"])
  defp env_for_transport(_transport, _params), do: %{}

  defp headers_for_transport(transport, params) when transport in ["streamable_http", "sse"],
    do: parse_headers(params["headers"])

  defp headers_for_transport(_transport, _params), do: %{}

  defp format_args(args) when is_list(args), do: Enum.join(args, "\n")
  defp format_args(_), do: ""

  defp format_env(env) when is_map(env) do
    env |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_env(_), do: ""

  defp format_headers(headers) when is_map(headers) do
    headers |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp format_headers(_headers), do: ""

  defp form_values_from_config(%MCPConfig{} = config) do
    %{
      "transport" => config.transport || "stdio",
      "command" => config.command || "",
      "args" => format_args(config.args),
      "url" => config.url || "",
      "env" => format_env(config.env),
      "headers" => format_headers(config.headers),
      "enabled" => config.enabled
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

      <.dm_card variant="bordered" class="mb-4">
        <:title>Live tool discovery</:title>
        <p :if={@config.provider_id} class="text-sm mb-2">
          Provider connection: {@config.provider_id}
        </p>
        <.dm_btn phx-click="refresh_catalog" disabled={@catalog_loading} size="sm">
          {if @catalog_loading, do: "Refreshing tools…", else: "Refresh live tools"}
        </.dm_btn>
        <p :if={@catalog_error} role="alert" class="text-error mt-2">{@catalog_error}</p>
      </.dm_card>

      <.dm_card variant="bordered">
        <.react_form
          for={%{}}
          id="mcp-config-form"
          class="space-y-4"
          values={@form_values}
          draft={react_form_draft(assigns, "mcp-config-form")}
          structure={form_value(@form_values, "transport", "stdio")}
          phx-submit="update_config"
          phx-change="change_config_form"
        >
          <.dm_react_field
            type="select"
            name="transport"
            label="Transport"
            options={[
              %{value: "stdio", label: "stdio"},
              %{value: "streamable_http", label: "Streamable HTTP"},
              %{value: "sse", label: "SSE"}
            ]}
          />

          <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 - preserve textarea rows and placeholders. --%>
          <div :if={form_value(@form_values, "transport", "stdio") == "stdio"} class="space-y-4">
            <.dm_react_field type="text" name="command" label="Command" />

            <.dm_textarea
              id="mcp-config-args"
              name="args"
              rows={3}
              label="Arguments (one per line)"
              value={form_value(@form_values, "args")}
            />

            <.dm_textarea
              id="mcp-config-env"
              name="env"
              rows={4}
              placeholder="GITHUB_TOKEN=ghp_xxx\nAPI_KEY=sk-xxx"
              label="Environment Variables (KEY=VALUE, one per line)"
              value={form_value(@form_values, "env")}
            />
          </div>

          <div
            :if={form_value(@form_values, "transport", "stdio") in ["streamable_http", "sse"]}
            class="space-y-4"
          >
            <.dm_react_field type="text" name="url" label="URL" />

            <.dm_textarea
              id="mcp-config-headers"
              name="headers"
              rows={4}
              placeholder="Authorization: Bearer token"
              label="Headers (Name: Value, one per line)"
              value={form_value(@form_values, "headers")}
            />
          </div>

          <div>
            <input type="hidden" name="enabled" value="false" />
            <.dm_checkbox
              id="mcp-config-enabled"
              name="enabled"
              value="true"
              checked={@config.enabled}
              label="Enabled"
            />
          </div>

          <.dm_btn type="submit" variant="primary">
            Save Changes
          </.dm_btn>
        </.react_form>
      </.dm_card>
    </.settings_layout>
    """
  end
end
