defmodule SynapsisWeb.MCPLive.Index do
  use SynapsisWeb, :live_view
  require Logger

  alias Synapsis.PluginConfigs

  @impl true
  def mount(_params, _session, socket) do
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
    assign(socket, show_form: true, selected_preset: nil, show_import: false)
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_form: false, selected_preset: nil, show_import: false)
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

  def handle_event("select_preset", %{"name" => name}, socket) do
    preset =
      SynapsisPlugin.MCP.Presets.all()
      |> Enum.find(&(&1.name == name))

    {:noreply, assign(socket, selected_preset: preset, custom_form: %{})}
  end

  def handle_event("select_custom", _params, socket) do
    custom = %{
      name: "",
      description: "Custom MCP server",
      command: "",
      args: [],
      env: %{},
      transport: "stdio",
      custom: true
    }

    {:noreply, assign(socket, selected_preset: custom, custom_form: %{"transport" => "stdio"})}
  end

  def handle_event("back_to_presets", _params, socket) do
    {:noreply, assign(socket, selected_preset: nil, custom_form: %{})}
  end

  def handle_event("change_custom_config", params, socket) do
    {:noreply, assign(socket, custom_form: Map.drop(params, ["_target"]))}
  end

  def handle_event("create_config", params, socket) do
    preset = socket.assigns.selected_preset
    transport = params["transport"] || preset.transport

    attrs = %{
      type: "mcp",
      name: params["name"] || preset.name,
      transport: transport,
      command: command_for_transport(transport, params, preset),
      url: url_for_transport(transport, params),
      args: args_for_transport(transport, params, preset),
      env: env_for_transport(transport, params, preset),
      settings: settings_for_transport(transport, params),
      auto_start: params["auto_start"] == "true"
    }

    case PluginConfigs.create(attrs) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(configs: list_configs(), show_form: false, selected_preset: nil)
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
    case PluginConfigs.get(id) do
      nil ->
        {:noreply, socket}

      config ->
        case PluginConfigs.update(config, %{auto_start: !config.auto_start}) do
          {:ok, _} -> {:noreply, assign(socket, configs: list_configs())}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update config")}
        end
    end
  end

  def handle_event("delete_config", %{"id" => id}, socket) do
    case PluginConfigs.get(id) do
      nil ->
        :ok

      config ->
        SynapsisPlugin.stop_plugin(config.name)
        PluginConfigs.delete(config)
    end

    configs = list_configs()
    {:noreply, assign(socket, configs: configs, plugin_states: load_plugin_states(configs))}
  end

  def handle_event("start_plugin", %{"name" => name}, socket) do
    case PluginConfigs.get_by_name_type(name, "mcp") do
      nil ->
        {:noreply, put_flash(socket, :error, "Config not found")}

      config ->
        plugin_config = %{
          name: config.name,
          transport: config.transport,
          command: config.command,
          url: config.url,
          args: config.args || [],
          env: config.env || %{},
          settings: config.settings || %{}
        }

        result =
          try do
            SynapsisPlugin.start_plugin(SynapsisPlugin.MCP, config.name, plugin_config)
          rescue
            e in [RuntimeError, ArgumentError] -> {:error, Exception.message(e)}
          catch
            _, _reason -> {:error, "plugin start failed"}
          end

        case result do
          {:ok, _pid} ->
            Process.send_after(self(), :refresh_plugin_states, 3000)

            {:noreply,
             socket
             |> refresh_states()
             |> put_flash(:info, "MCP server '#{name}' starting...")}

          {:error, reason} ->
            Logger.warning("mcp_start_failed", name: name, reason: inspect(reason))
            {:noreply, put_flash(socket, :error, "Failed to start MCP server")}
        end
    end
  end

  def handle_event("stop_plugin", %{"name" => name}, socket) do
    SynapsisPlugin.stop_plugin(name)
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_states(socket) do
    configs = list_configs()
    assign(socket, configs: configs, plugin_states: load_plugin_states(configs))
  end

  defp list_configs, do: PluginConfigs.list_by_type("mcp")

  defp load_plugin_states(configs) do
    stopped = %{running: false, initialized: false, server_info: nil, tools: []}

    for config <- configs, into: %{} do
      info =
        try do
          case SynapsisPlugin.get_plugin_state(config.name) do
            {:ok, %SynapsisPlugin.MCP{} = state} ->
              %{
                running: true,
                initialized: state.initialized || false,
                server_info: state.server_info,
                tools: state.tools || []
              }

            _ ->
              stopped
          end
        rescue
          _e in [RuntimeError, ArgumentError] -> stopped
        catch
          _, _ -> stopped
        end

      {config.name, info}
    end
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
          type: "mcp",
          name: name,
          transport: Map.get(config, "transport", "stdio"),
          command: Map.get(config, "command", ""),
          url: Map.get(config, "url"),
          args: Map.get(config, "args", []),
          env: Map.get(config, "env", %{}),
          auto_start: Map.get(config, "autoStart", false)
        }

        case PluginConfigs.create(attrs) do
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

  defp command_for_transport("stdio", params, preset), do: params["command"] || preset.command
  defp command_for_transport(_transport, _params, _preset), do: ""

  defp url_for_transport(transport, params) when transport in ["http", "sse"], do: params["url"]
  defp url_for_transport(_transport, _params), do: nil

  defp args_for_transport("stdio", params, preset) do
    if(params["args"], do: parse_args(params["args"]), else: preset.args)
  end

  defp args_for_transport(_transport, _params, _preset), do: []

  defp env_for_transport("stdio", params, preset) do
    if(params["env"], do: parse_env(params["env"]), else: preset.env)
  end

  defp env_for_transport(_transport, _params, _preset), do: %{}

  defp settings_for_transport(transport, params) when transport in ["http", "sse"] do
    headers = parse_headers(params["headers"])
    if headers == %{}, do: %{}, else: %{"headers" => headers}
  end

  defp settings_for_transport(_transport, _params), do: %{}

  @impl true
  def render(assigns) do
    presets = SynapsisPlugin.MCP.Presets.all()
    configured = Enum.map(assigns.configs, & &1.name)

    assigns =
      assign(assigns,
        presets: presets,
        configured_names: configured,
        custom_form: Map.get(assigns, :custom_form, %{}),
        custom_transport: custom_transport(assigns)
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
        <%= if @selected_preset do %>
          <.dm_card variant="bordered" class="mb-6">
            <div class="flex items-center gap-3 mb-4">
              <.dm_btn variant="ghost" size="sm" phx-click="back_to_presets">
                &larr; Back
              </.dm_btn>
              <h2 class="text-lg font-semibold">
                <%= if Map.get(@selected_preset, :custom) do %>
                  New Custom MCP Server
                <% else %>
                  Add {@selected_preset.name}
                <% end %>
              </h2>
            </div>
            <.dm_form
              for={%{}}
              phx-submit="create_config"
              phx-change={if Map.get(@selected_preset, :custom), do: "change_custom_config"}
            >
              <%= if Map.get(@selected_preset, :custom) do %>
                <.dm_input
                  type="text"
                  name="name"
                  value={form_value(@custom_form, "name")}
                  placeholder="Server name"
                  required
                  label="Name"
                />
              <% else %>
                <.readonly_field label="Name" value={@selected_preset.name} />
              <% end %>
              <%= if Map.get(@selected_preset, :custom) do %>
                <.dm_select
                  name="transport"
                  label="Transport"
                  options={[{"stdio", "stdio"}, {"http", "HTTP"}]}
                  value={@custom_transport}
                />
              <% else %>
                <.readonly_field label="Transport" value={@selected_preset.transport} />
              <% end %>
              <div :if={Map.get(@selected_preset, :custom) && @custom_transport in ["http", "sse"]}>
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
              <%= if Map.get(@selected_preset, :custom) && @custom_transport == "stdio" do %>
                <.dm_input
                  type="text"
                  name="command"
                  value={form_value(@custom_form, "command")}
                  placeholder="e.g. npx"
                  label="Command"
                />
              <% else %>
                <%= if !Map.get(@selected_preset, :custom) do %>
                  <.dm_input
                    type="text"
                    name="command"
                    value={@selected_preset.command}
                    readonly
                    label="Command"
                  />
                <% end %>
              <% end %>
              <%= if Map.get(@selected_preset, :custom) && @custom_transport == "stdio" do %>
                <.dm_textarea
                  name="args"
                  value={form_value(@custom_form, "args")}
                  rows={3}
                  placeholder="One argument per line"
                  label="Arguments (one per line)"
                />
              <% else %>
                <%= if !Map.get(@selected_preset, :custom) do %>
                  <.readonly_field
                    label="Arguments (one per line)"
                    value={Enum.join(@selected_preset.args, "\n")}
                    monospace
                  />
                <% end %>
              <% end %>
              <div :if={
                (Map.get(@selected_preset, :custom) && @custom_transport == "stdio") ||
                  (!Map.get(@selected_preset, :custom) && map_size(@selected_preset.env) > 0)
              }>
                <.dm_textarea
                  name="env"
                  rows={3}
                  placeholder="KEY=VALUE"
                  label="Environment Variables (KEY=VALUE, one per line)"
                  value={
                    if Map.get(@selected_preset, :custom),
                      do: form_value(@custom_form, "env"),
                      else: format_env_for_form(@selected_preset.env)
                  }
                />
                <div
                  :if={!Map.get(@selected_preset, :custom) && has_required_env?(@selected_preset)}
                  class="text-xs text-warning mt-1"
                >
                  Fill in the required environment variable values above
                </div>
              </div>
              <div>
                <input type="hidden" name="auto_start" value="false" />
                <.dm_checkbox
                  name="auto_start"
                  value="true"
                  label="Auto-start on startup"
                />
              </div>
              <.dm_btn type="submit" variant="primary">
                Add MCP Server
              </.dm_btn>
            </.dm_form>
          </.dm_card>
        <% else %>
          <div class="mb-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold">Select an MCP Server</h2>
              <.dm_link
                navigate={~p"/settings/mcp"}
                class="text-on-surface-variant hover:text-on-surface text-sm"
              >
                Cancel
              </.dm_link>
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <div
                :for={preset <- @presets}
                phx-click={if(preset.name not in @configured_names, do: "select_preset")}
                phx-value-name={preset.name}
                class={[
                  "w-full text-left",
                  if(preset.name not in @configured_names, do: "cursor-pointer")
                ]}
                role="button"
                tabindex="0"
              >
                <.dm_card
                  variant="bordered"
                  class={[
                    if(preset.name in @configured_names,
                      do: "opacity-50 cursor-not-allowed",
                      else: "cursor-pointer hover:border-primary"
                    )
                  ]}
                >
                  <div class="font-medium">{preset.name}</div>
                  <div class="text-xs text-on-surface-variant mt-1">{preset.description}</div>
                  <div class="text-xs text-on-surface-variant mt-1 font-mono">
                    {preset.command} {Enum.join(preset.args, " ")}
                  </div>
                  <div
                    :if={preset.name in @configured_names}
                    class="text-xs text-on-surface-variant mt-1"
                  >
                    Already configured
                  </div>
                </.dm_card>
              </div>
            </div>

            <h3 class="text-sm font-semibold text-on-surface-variant mt-6 mb-3">Custom</h3>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <div
                phx-click="select_custom"
                class="w-full text-left cursor-pointer"
                role="button"
                tabindex="0"
              >
                <.dm_card variant="bordered" class="cursor-pointer border-dashed hover:border-primary">
                  <div class="font-medium">Custom MCP Server</div>
                  <div class="text-xs text-on-surface-variant mt-1">
                    Configure a custom stdio or HTTP server
                  </div>
                </.dm_card>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.dm_card
          :for={config <- @configs}
          variant="bordered"
        >
          <% ps = Map.get(@plugin_states, config.name, %{running: false}) %>
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
                checked={config.auto_start}
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
          <%!-- Server info from initialize response --%>
          <div
            :if={ps[:running] && ps[:server_info]}
            class="mt-2 p-2 bg-surface-container rounded text-xs"
          >
            <div class="font-semibold text-on-surface-variant mb-1">Server Info</div>
            <div :if={ps[:server_info]["serverInfo"]} class="text-on-surface-variant">
              {ps[:server_info]["serverInfo"]["name"]}
              <span :if={ps[:server_info]["serverInfo"]["version"]}>
                v{ps[:server_info]["serverInfo"]["version"]}
              </span>
            </div>
            <div :if={ps[:server_info]["protocolVersion"]} class="text-on-surface-variant">
              Protocol: {ps[:server_info]["protocolVersion"]}
            </div>
            <div :if={ps[:server_info]["capabilities"]} class="text-on-surface-variant">
              Capabilities: {ps[:server_info]["capabilities"] |> Map.keys() |> Enum.join(", ")}
            </div>
          </div>
          <div class="mt-2 flex items-center gap-2 flex-wrap">
            <span :if={config.auto_start} class="badge badge-sm badge-success">
              Auto-start
            </span>
            <span :if={!config.auto_start} class="badge badge-sm badge-ghost">
              Manual
            </span>
            <span :if={ps[:running] && ps[:initialized]} class="badge badge-sm badge-info">
              Running
            </span>
            <span :if={ps[:running] && !ps[:initialized]} class="badge badge-sm badge-warning">
              Initializing
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
                      {tool["name"]}
                    </div>
                    <div :if={tool["description"]} class="text-sm text-on-surface-variant mt-1">
                      {tool["description"]}
                    </div>
                    <div :if={tool["inputSchema"]} class="mt-2">
                      <details class="cursor-pointer">
                        <summary class="text-xs text-on-surface-variant hover:text-on-surface-variant">
                          Input Schema
                        </summary>
                        <pre class="text-xs bg-surface-container p-2 rounded mt-1 overflow-x-auto"><code>{Jason.encode!(tool["inputSchema"], pretty: true)}</code></pre>
                      </details>
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

  defp format_env_for_form(env) when is_map(env) and map_size(env) > 0 do
    env |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_env_for_form(_), do: ""

  defp form_value(form, key, default \\ "") when is_map(form) do
    Map.get(form, key, default) || default
  end

  defp custom_transport(%{selected_preset: %{custom: true}, custom_form: form}) do
    form_value(form || %{}, "transport", "stdio")
  end

  defp custom_transport(%{selected_preset: %{transport: transport}}), do: transport || "stdio"
  defp custom_transport(_assigns), do: "stdio"

  defp has_required_env?(%{env: env}) when is_map(env) do
    Enum.any?(env, fn {_k, v} -> v == "" end)
  end

  defp has_required_env?(_), do: false

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
