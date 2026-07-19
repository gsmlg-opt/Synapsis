defmodule SynapsisWeb.MCPLive.Index do
  use SynapsisWeb, :live_view
  require Logger

  alias Synapsis.MCPConfigs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_registry")
    end

    {:ok,
     assign(socket,
       configs: [],
       page_title: "MCP Servers",
       plugin_states: %{},
       custom_form: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    configs = list_configs()
    plugin_states = load_plugin_states(configs)

    {:noreply,
     apply_action(socket, socket.assigns.live_action, params)
     |> assign(configs: configs, plugin_states: plugin_states)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, show_form: true, show_import: false, custom_form: %{"transport" => "stdio"})
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_form: false, show_import: false)
  end

  @impl true
  def handle_event("show_import", _params, socket) do
    {:noreply, assign(socket, show_import: true, import_json: "")}
  end

  def handle_event("hide_import", _params, socket) do
    {:noreply, assign(socket, show_import: false)}
  end

  def handle_event("import_json", %{"json" => json}, socket) do
    case parse_mcp_json(json) do
      {:ok, servers} when map_size(servers) == 0 ->
        {:noreply, put_flash(socket, :error, "No MCP servers found in JSON")}

      {:ok, servers} ->
        configured = Enum.map(socket.assigns.configs, & &1.name) |> MapSet.new()
        {imported, skipped} = import_mcp_servers(servers, configured)

        msg =
          case {imported, skipped} do
            {0, s} -> "No new servers imported (#{s} already configured)"
            {i, 0} -> "Imported #{i} MCP server(s)"
            {i, s} -> "Imported #{i} MCP server(s), skipped #{s} already configured"
          end

        {:noreply,
         socket
         |> assign(show_import: false, configs: list_configs())
         |> put_flash(:info, msg)}

      {:error, reason} ->
        Logger.warning("mcp_import_invalid_json", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Invalid JSON format")}
    end
  end

  def handle_event("change_custom_config", params, socket) do
    {:noreply, assign(socket, custom_form: Map.drop(params, ["_target"]))}
  end

  def handle_event("create_config", params, socket) do
    transport = params["transport"] || "stdio"

    attrs = %{
      name: params["name"],
      transport: transport,
      command: command_for_transport(transport, params),
      url: url_for_transport(transport, params),
      args: args_for_transport(transport, params),
      env: env_for_transport(transport, params),
      headers: headers_for_transport(transport, params),
      enabled: params["enabled"] == "true"
    }

    case MCPConfigs.create(attrs) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(configs: list_configs(), show_form: false)
         |> put_flash(:info, "MCP server added")
         |> push_navigate(to: ~p"/settings/mcp")}

      {:error, %Ecto.Changeset{errors: errors}} ->
        msg =
          case Keyword.get(errors, :name) do
            {"has already been taken", _} -> "Name already taken"
            _ -> "Failed to add MCP server"
          end

        {:noreply, put_flash(socket, :error, msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add MCP server")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    case MCPConfigs.get(id) do
      nil ->
        {:noreply, socket}

      config ->
        case MCPConfigs.update(config, %{enabled: !config.enabled}) do
          {:ok, _} -> {:noreply, assign(socket, configs: list_configs())}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update config")}
        end
    end
  end

  def handle_event("delete_config", %{"id" => id}, socket) do
    case MCPConfigs.get(id) do
      nil ->
        :ok

      config ->
        Synapsis.MCP.stop(config.name)
        MCPConfigs.delete(config)
    end

    configs = list_configs()
    {:noreply, assign(socket, configs: configs, plugin_states: load_plugin_states(configs))}
  end

  def handle_event("start_plugin", %{"name" => name}, socket) do
    case MCPConfigs.get_by_name(name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Config not found")}

      config ->
        case Synapsis.MCP.start(config) do
          {:ok, _pid} ->
            Process.send_after(self(), :refresh_plugin_states, 3000)

            {:noreply,
             socket
             |> refresh_states()
             |> put_flash(:info, "MCP server '#{name}' starting...")}

          {:error, reason} ->
            Logger.warning("mcp_start_failed", name: name, reason: inspect(reason))

            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to start MCP server '#{name}': #{format_start_error(reason)}"
             )}
        end
    end
  end

  def handle_event("restart_plugin", %{"name" => name}, socket) do
    case MCPConfigs.get_by_name(name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Config not found")}

      config ->
        case Synapsis.MCP.restart(config) do
          :ok ->
            Process.send_after(self(), :refresh_plugin_states, 3000)

            {:noreply,
             socket
             |> refresh_states()
             |> put_flash(:info, "MCP server '#{name}' restarting...")}

          {:error, reason} ->
            Logger.warning("mcp_restart_failed", name: name, reason: inspect(reason))

            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to restart MCP server '#{name}': #{format_start_error(reason)}"
             )}
        end
    end
  end

  def handle_event("stop_plugin", %{"name" => name}, socket) do
    Synapsis.MCP.stop(name)
    configs = list_configs()

    {:noreply,
     socket
     |> assign(configs: configs, plugin_states: load_plugin_states(configs))
     |> put_flash(:info, "MCP server '#{name}' stopped")}
  end

  @impl true
  def handle_info(:refresh_plugin_states, socket) do
    {:noreply, refresh_states(socket)}
  end

  def handle_info({:tool_registry_changed, _payload}, socket) do
    {:noreply, refresh_states(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_states(socket) do
    configs = list_configs()
    assign(socket, configs: configs, plugin_states: load_plugin_states(configs))
  end

  defp list_configs, do: MCPConfigs.list()

  # Derive running status from Synapsis.MCP.list/0 and tool names from the tool
  # registry: MCP tools are registered as "mcp:<server_name>:<tool>".
  defp load_plugin_states(configs) do
    running = MapSet.new(Synapsis.MCP.list())

    for config <- configs, into: %{} do
      running? = MapSet.member?(running, config.name)
      tools = if running?, do: tools_for_server(config.name), else: []
      {config.name, %{running: running?, tools: tools}}
    end
  end

  defp tools_for_server(name) do
    prefix = "mcp:#{name}:"

    Synapsis.Tool.Registry.list()
    |> Enum.filter(fn tool -> String.starts_with?(to_string(tool.name), prefix) end)
  end

  defp parse_mcp_json(json) do
    case Jason.decode(json) do
      {:ok, %{"mcpServers" => servers}} when is_map(servers) ->
        {:ok, servers}

      {:ok, data} when is_map(data) ->
        # Support bare format without mcpServers wrapper if all values look like server configs
        if Enum.all?(data, fn {_k, v} -> is_map(v) and is_binary(Map.get(v, "command", nil)) end) do
          {:ok, data}
        else
          {:error, "expected {\"mcpServers\": {...}} format"}
        end

      {:ok, _} ->
        {:error, "expected a JSON object"}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, Exception.message(err)}
    end
  end

  defp import_mcp_servers(servers, configured) do
    Enum.reduce(servers, {0, 0}, fn {name, config}, {imported, skipped} ->
      if MapSet.member?(configured, name) do
        {imported, skipped + 1}
      else
        attrs = %{
          name: name,
          transport: Map.get(config, "transport", "stdio"),
          command: Map.get(config, "command", ""),
          url: Map.get(config, "url"),
          args: Map.get(config, "args", []),
          env: Map.get(config, "env", %{}),
          enabled: Map.get(config, "enabled", false)
        }

        case MCPConfigs.create(attrs) do
          {:ok, _} -> {imported + 1, skipped}
          {:error, _} -> {imported, skipped + 1}
        end
      end
    end)
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

  defp url_for_transport(transport, params) when transport in ["streamable_http", "sse"],
    do: params["url"]

  defp url_for_transport(_transport, _params), do: nil

  defp args_for_transport("stdio", params), do: parse_args(params["args"])
  defp args_for_transport(_transport, _params), do: []

  defp env_for_transport("stdio", params), do: parse_env(params["env"])
  defp env_for_transport(_transport, _params), do: %{}

  defp headers_for_transport(transport, params) when transport in ["streamable_http", "sse"],
    do: parse_headers(params["headers"])

  defp headers_for_transport(_transport, _params), do: %{}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        custom_form: Map.get(assigns, :custom_form, %{}),
        custom_transport: form_value(Map.get(assigns, :custom_form, %{}), "transport", "stdio")
      )

    ~H"""
    <.settings_layout current_path="/settings/mcp" content_class="max-w-5xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>MCP Servers</:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">MCP Servers</h1>
        <div :if={!@show_form} class="flex gap-2">
          <.dm_btn variant="ghost" size="sm" phx-click="show_import">
            <.dm_mdi name="code-json" class="w-4 h-4 mr-1" /> Import JSON
          </.dm_btn>
          <.dm_link navigate={~p"/settings/mcp/new"}>
            <.dm_btn variant="primary" size="sm">+ Add MCP Server</.dm_btn>
          </.dm_link>
        </div>
      </div>

      <%!-- Import JSON form --%>
      <.dm_card :if={@show_import} variant="bordered" class="mb-6">
        <div class="flex items-center gap-3 mb-4">
          <.dm_btn variant="ghost" size="sm" phx-click="hide_import">
            &larr; Back
          </.dm_btn>
          <h2 class="text-lg font-semibold">Import MCP Servers from JSON</h2>
        </div>
        <p class="text-sm text-on-surface-variant mb-3">
          Paste JSON in Claude Code
          <code class="text-xs bg-surface-container px-1 rounded">mcp.json</code>
          format.
          Supports both <code class="text-xs bg-surface-container px-1 rounded">mcpServers</code>
          wrapper and bare server objects.
        </p>
        <details class="mb-3">
          <summary class="text-xs text-on-surface-variant cursor-pointer hover:text-on-surface-variant">
            Example format
          </summary>
          <pre class="text-xs bg-surface-container p-3 rounded mt-1 overflow-x-auto"><code>{mcp_import_example()}</code></pre>
        </details>
        <.dm_form for={%{}} phx-submit="import_json">
          <.dm_textarea
            name="json"
            value=""
            rows={10}
            placeholder={mcp_import_placeholder()}
            label="JSON"
          />
          <div class="flex gap-2 mt-3">
            <.dm_btn type="submit" variant="primary">Import</.dm_btn>
            <.dm_btn type="button" variant="ghost" phx-click="hide_import">Cancel</.dm_btn>
          </div>
        </.dm_form>
      </.dm_card>

      <%= if @show_form do %>
        <.dm_card variant="bordered" class="mb-6">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold">New MCP Server</h2>
            <.dm_link
              navigate={~p"/settings/mcp"}
              class="text-on-surface-variant hover:text-on-surface text-sm"
            >
              Cancel
            </.dm_link>
          </div>
          <.dm_form for={%{}} phx-submit="create_config" phx-change="change_custom_config">
            <.dm_input
              type="text"
              name="name"
              value={form_value(@custom_form, "name")}
              placeholder="Server name"
              required
              label="Name"
            />
            <.dm_select
              name="transport"
              label="Transport"
              options={[
                {"stdio", "stdio"},
                {"streamable_http", "Streamable HTTP"},
                {"sse", "SSE"}
              ]}
              value={@custom_transport}
            />
            <div :if={@custom_transport in ["streamable_http", "sse"]}>
              <.dm_input
                type="text"
                name="url"
                value={form_value(@custom_form, "url")}
                placeholder="http://localhost:7331/mcp"
                label="URL"
              />
              <.dm_textarea
                name="headers"
                value={form_value(@custom_form, "headers")}
                rows={4}
                placeholder="Authorization: Bearer token"
                label="Headers (Name: Value, one per line)"
              />
            </div>
            <div :if={@custom_transport == "stdio"}>
              <.dm_input
                type="text"
                name="command"
                value={form_value(@custom_form, "command")}
                placeholder="e.g. npx"
                label="Command"
              />
              <.dm_textarea
                name="args"
                value={form_value(@custom_form, "args")}
                rows={3}
                placeholder="One argument per line"
                label="Arguments (one per line)"
              />
              <.dm_textarea
                name="env"
                rows={3}
                placeholder="KEY=VALUE"
                label="Environment Variables (KEY=VALUE, one per line)"
                value={form_value(@custom_form, "env")}
              />
            </div>
            <div>
              <input type="hidden" name="enabled" value="false" />
              <.dm_checkbox
                name="enabled"
                value="true"
                label="Enabled"
              />
            </div>
            <.dm_btn type="submit" variant="primary">
              Add MCP Server
            </.dm_btn>
          </.dm_form>
        </.dm_card>
      <% end %>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.dm_card
          :for={config <- @configs}
          variant="bordered"
        >
          <% ps = Map.get(@plugin_states, config.name, %{running: false, tools: []}) %>
          <div class="flex justify-between items-start mb-2">
            <.dm_link
              navigate={~p"/settings/mcp/#{config.id}"}
              class="font-medium hover:text-primary transition-colors"
            >
              {config.name}
            </.dm_link>
            <div class="flex items-center gap-2">
              <.dm_switch
                name={"toggle_#{config.id}"}
                checked={config.enabled}
                phx-click="toggle_enabled"
                phx-value-id={config.id}
              />
              <.dm_btn
                variant="ghost"
                size="xs"
                class="text-error hover:text-error/80 ml-1"
                confirm="Delete this MCP server?"
                phx-click="delete_config"
                phx-value-id={config.id}
              >
                Delete
              </.dm_btn>
            </div>
          </div>
          <div class="text-xs text-on-surface-variant">
            {config.transport}
            <span :if={config.command}>{" | #{config.command}"}</span>
            <span :if={config.args != []}>
              {" " <> Enum.join(config.args, " ")}
            </span>
          </div>
          <div :if={config.url} class="text-xs text-on-surface-variant mt-1 truncate">
            {config.url}
          </div>
          <div :if={map_size(config.env || %{}) > 0} class="text-xs text-warning mt-1">
            {"#{map_size(config.env)} env var(s)"}
          </div>
          <div class="mt-2 flex items-center gap-2 flex-wrap">
            <span :if={config.enabled} class="badge badge-sm badge-success">
              Enabled
            </span>
            <span :if={!config.enabled} class="badge badge-sm badge-ghost">
              Disabled
            </span>
            <span :if={ps[:running]} class="badge badge-sm badge-info">
              Running
            </span>
            <span :if={!ps[:running]} class="badge badge-sm badge-ghost">
              Stopped
            </span>
            <.dm_btn
              :if={!ps[:running]}
              variant="primary"
              size="xs"
              phx-click="start_plugin"
              phx-value-name={config.name}
            >
              Start
            </.dm_btn>
            <.dm_btn
              :if={ps[:running]}
              variant="ghost"
              size="xs"
              phx-click="restart_plugin"
              phx-value-name={config.name}
            >
              Restart
            </.dm_btn>
            <.dm_btn
              :if={ps[:running]}
              variant="ghost"
              size="xs"
              phx-click="stop_plugin"
              phx-value-name={config.name}
            >
              Stop
            </.dm_btn>
            <%!-- Tools button with count --%>
            <.dm_modal
              :if={ps[:running] && ps[:tools] != []}
              id={"tools-modal-#{config.id}"}
              size="lg"
              backdrop
            >
              <:trigger :let={dialog_id}>
                <.dm_btn
                  variant="ghost"
                  size="xs"
                  class="text-primary"
                  onclick={"document.getElementById('#{dialog_id}').show()"}
                >
                  <.dm_mdi name="puzzle-outline" class="w-3 h-3 mr-1" />
                  {length(ps[:tools])} tool(s)
                </.dm_btn>
              </:trigger>
              <:title>Tools — {config.name}</:title>
              <:body>
                <div class="w-full overflow-y-auto max-h-96">
                  <div
                    :for={tool <- ps[:tools]}
                    class="border-b border-outline-variant last:border-b-0 py-3"
                  >
                    <div class="font-mono text-sm font-semibold text-primary">
                      {tool.name}
                    </div>
                    <div :if={tool.description} class="text-sm text-on-surface-variant mt-1">
                      {tool.description}
                    </div>
                  </div>
                </div>
              </:body>
            </.dm_modal>
          </div>
        </.dm_card>
      </div>

      <div :if={@configs == [] && !@show_form} class="text-center text-on-surface-variant py-12">
        No MCP servers configured. Click "+ Add MCP Server" to get started.
      </div>
    </.settings_layout>
    """
  end

  # Turn a plugin start failure into a concise, actionable flash message. The
  # raw reason (full body, stacktrace) is still logged via mcp_start_failed.
  defp format_start_error({:http_error, status, body}),
    do: "server returned HTTP #{status} — #{first_line(body)}"

  defp format_start_error({:no_binary, command}), do: "executable not found: #{command}"
  defp format_start_error({:missing_url, _name}), do: "no URL configured for HTTP transport"

  defp format_start_error({:unsupported_transport, transport}),
    do: "unsupported transport: #{transport}"

  defp format_start_error({:already_started, _pid}), do: "already running"
  defp format_start_error(reason) when is_binary(reason), do: first_line(reason)
  defp format_start_error(reason), do: first_line(inspect(reason))

  defp first_line(value) do
    value
    |> to_string()
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.slice(0, 200)
  end

  defp form_value(form, key, default \\ "") when is_map(form) do
    Map.get(form, key, default) || default
  end

  defp mcp_import_example do
    Jason.encode!(
      %{
        "mcpServers" => %{
          "filesystem" => %{
            "command" => "npx",
            "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            "env" => %{}
          }
        }
      },
      pretty: true
    )
  end

  defp mcp_import_placeholder do
    ~s|{"mcpServers": {"server-name": {"command": "npx", "args": [...]}}}|
  end
end
