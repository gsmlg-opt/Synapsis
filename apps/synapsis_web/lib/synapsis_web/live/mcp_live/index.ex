defmodule SynapsisWeb.MCPLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents
  require Logger

  alias Synapsis.MCPConfigs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_registry")
      Synapsis.Providers.subscribe()
      send(self(), :refresh_connected_catalog)
    end

    {:ok,
     assign(socket,
       configs: [],
       page_title: "MCP Servers",
       plugin_states: %{},
       custom_form: %{},
       show_form: false,
       show_import: false,
       modal_error: nil,
       source_providers: Synapsis.Backplane.ProviderSource.available(),
       catalog_loading: false,
       catalog_errors: %{}
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
    socket
    |> reset_react_form("mcp-create-form")
    |> clear_flash(:error)
    |> assign(
      show_form: true,
      show_import: false,
      modal_error: nil,
      custom_form: %{"provider_id" => "", "transport" => "stdio"}
    )
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_form: false)
  end

  @impl true
  def handle_event("refresh_catalog", _params, %{assigns: %{catalog_loading: true}} = socket),
    do: {:noreply, socket}

  def handle_event("refresh_catalog", _params, socket) do
    {:noreply,
     socket
     |> assign(catalog_loading: true, catalog_errors: %{})
     |> start_async(:mcp_catalog, fn -> Synapsis.MCPSelection.refresh() end)}
  end

  def handle_event("show_import", _params, socket) do
    socket =
      socket
      |> assign(show_import: true, show_form: false, modal_error: nil)
      |> clear_flash(:error)
      |> reset_react_form("mcp-import-form", %{"json" => ""})

    socket =
      if socket.assigns.live_action == :new,
        do: push_patch(socket, to: ~p"/settings/mcp"),
        else: socket

    {:noreply, socket}
  end

  def handle_event("hide_import", _params, socket) do
    {:noreply,
     socket
     |> reset_react_form("mcp-import-form")
     |> assign(show_import: false, modal_error: nil)
     |> clear_flash(:error)}
  end

  def handle_event("hide_create", _params, socket) do
    {:noreply,
     socket
     |> reset_react_form("mcp-create-form")
     |> assign(show_form: false, show_import: false, modal_error: nil)
     |> clear_flash(:error)
     |> push_patch(to: ~p"/settings/mcp")}
  end

  def handle_event("import_json", %{"json" => json}, socket) do
    case parse_mcp_json(json) do
      {:ok, servers} when map_size(servers) == 0 ->
        {:noreply, modal_error(socket, "No MCP servers found in JSON")}

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
         |> assign(show_import: false, modal_error: nil, configs: list_configs())
         |> reset_react_form("mcp-import-form")
         |> put_flash(:info, msg)}

      {:error, reason} ->
        Logger.warning("mcp_import_invalid_json", reason: inspect(reason))
        {:noreply, modal_error(socket, "Invalid JSON format")}
    end
  end

  def handle_event("change_custom_config", params, socket) do
    form = Map.merge(socket.assigns.custom_form, Map.drop(params, ["_target"]))

    socket =
      if form_value(form, "provider_id") != form_value(socket.assigns.custom_form, "provider_id") do
        form = Map.put(form, "url", "")

        socket
        |> assign(custom_form: form, modal_error: nil)
        |> reset_react_form("mcp-create-form", form)
      else
        assign(socket, custom_form: form)
      end

    {:noreply, socket}
  end

  def handle_event("create_config", %{"provider_id" => provider_id} = params, socket)
      when is_binary(provider_id) and provider_id != "" do
    case Synapsis.Backplane.select_mcp_provider(provider_id, params["url"]) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> refresh_states()
         |> assign(show_form: false, modal_error: nil)
         |> reset_react_form("mcp-create-form")
         |> put_flash(:info, "MCP server added")
         |> push_patch(to: ~p"/settings/mcp")}

      {:error, _} ->
        {:noreply, modal_error(socket, "Provider connection is unavailable")}
    end
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
         |> assign(configs: list_configs(), show_form: false, modal_error: nil)
         |> reset_react_form("mcp-create-form")
         |> put_flash(:info, "MCP server added")
         |> push_patch(to: ~p"/settings/mcp")}

      {:error, %Ecto.Changeset{errors: errors}} ->
        msg =
          cond do
            Keyword.has_key?(errors, :headers) ->
              "Invalid headers. Use Name: Value, one per line, without JSON braces."

            match?({"has already been taken", _}, Keyword.get(errors, :name)) ->
              "Name already taken"

            true ->
              "Failed to add MCP server"
          end

        {:noreply, modal_error(socket, msg)}

      {:error, _} ->
        {:noreply, modal_error(socket, "Failed to add MCP server")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    case MCPConfigs.get(id) do
      nil ->
        {:noreply, socket}

      config ->
        case MCPConfigs.update(config, %{enabled: !config.enabled}) do
          {:ok, updated} ->
            socket =
              if updated.enabled do
                refresh_states(socket)
              else
                stop_disabled_server(socket, updated.name)
              end

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update config")}
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
  def handle_info(:refresh_connected_catalog, socket) do
    {:noreply,
     socket
     |> assign(catalog_loading: true)
     |> start_async(:mcp_catalog, fn -> Synapsis.MCPSelection.refresh() end)}
  end

  def handle_info(:refresh_plugin_states, socket) do
    {:noreply, refresh_states(socket)}
  end

  def handle_info({:tool_registry_changed, _payload}, socket) do
    {:noreply, refresh_states(socket)}
  end

  def handle_info({:provider_catalog_changed}, socket), do: {:noreply, refresh_states(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:mcp_catalog, {:ok, outcomes}, socket) when is_map(outcomes) do
    errors = Map.reject(outcomes, fn {_id, outcome} -> outcome == :ok end)

    {:noreply,
     socket |> assign(catalog_loading: false, catalog_errors: errors) |> refresh_states()}
  end

  def handle_async(:mcp_catalog, _failure, socket) do
    {:noreply,
     assign(socket, catalog_loading: false, catalog_errors: %{"catalog" => "Refresh failed"})}
  end

  defp refresh_states(socket) do
    configs = list_configs()

    assign(socket,
      configs: configs,
      plugin_states: load_plugin_states(configs),
      source_providers: Synapsis.Backplane.ProviderSource.available()
    )
  end

  defp stop_disabled_server(socket, name) do
    case Synapsis.MCP.stop(name) do
      :ok ->
        refresh_states(socket)

      {:error, :not_found} ->
        refresh_states(socket)

      {:error, reason} ->
        Logger.warning("mcp_disable_stop_failed", name: name, reason: inspect(reason))

        socket
        |> refresh_states()
        |> put_flash(:error, "MCP server was disabled but could not be stopped")
    end
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
        custom_provider: form_value(Map.get(assigns, :custom_form, %{}), "provider_id"),
        custom_transport: form_value(Map.get(assigns, :custom_form, %{}), "transport", "stdio")
      )

    ~H"""
    <.settings_layout current_path="/settings/mcp" content_class="max-w-5xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>MCP Servers</:crumb>
      </.breadcrumb>

      <div class="flex flex-col gap-3 sm:flex-row sm:justify-between sm:items-center mb-6">
        <h1 class="text-2xl font-bold">MCP Servers</h1>
        <div class="flex flex-wrap items-center gap-2">
          <.dm_btn variant="ghost" size="sm" phx-click="refresh_catalog" disabled={@catalog_loading}>
            {if @catalog_loading, do: "Refreshing tools…", else: "Refresh live tools"}
          </.dm_btn>
          <.dm_btn variant="ghost" size="sm" phx-click="show_import">
            <.dm_mdi name="code-json" class="w-4 h-4 mr-1" /> Import JSON
          </.dm_btn>
          <.dm_link patch={~p"/settings/mcp/new"}>
            <.dm_btn variant="primary" size="sm">+ Add MCP Server</.dm_btn>
          </.dm_link>
        </div>
      </div>

      <div :if={map_size(@catalog_errors) > 0} class="mb-4 space-y-2">
        <p :for={{id, _error} <- @catalog_errors} role="alert" class="text-error text-sm">
          Tool discovery failed for {id}. Tools are unavailable until a successful refresh.
        </p>
      </div>

      <%!-- Import JSON form --%>
      <.dm_modal
        :if={@show_import}
        id="mcp-import-modal"
        size="lg"
        class="synapsis-mcp-modal"
        phx-hook="MCPFormModal"
        data-close-event="hide_import"
      >
        <:title>Import MCP Servers from JSON</:title>
        <:body>
          <div
            :if={@modal_error}
            role="alert"
            aria-live="polite"
            class="mb-4 rounded-lg border border-error bg-error-container p-3 text-sm text-on-error-container"
          >
            {@modal_error}
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
          <.react_form
            for={%{}}
            id="mcp-import-form"
            class="space-y-4"
            draft={react_form_draft(assigns, "mcp-import-form")}
            phx-submit="import_json"
          >
            <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 - preserve placeholder and textarea layout attributes. --%>
            <.dm_textarea
              id="mcp-import-json"
              autofocus
              name="json"
              value=""
              rows={10}
              placeholder={mcp_import_placeholder()}
              label="JSON"
            />
            <div class="flex gap-2 mt-3">
              <%!-- # TODO(upstream): duskmoon-dev/duskmoon-elements#88 - remove after reconnect-safe button listeners ship.
                   # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#88 - native submission avoids duplicate requests after validation. --%>
              <.dm_btn type="submit" native_submit variant="primary">Import</.dm_btn>
              <.dm_btn type="button" variant="ghost" phx-click="hide_import">Cancel</.dm_btn>
            </div>
          </.react_form>
        </:body>
      </.dm_modal>

      <.dm_modal
        :if={@show_form}
        id="mcp-create-modal"
        size="lg"
        class="synapsis-mcp-modal"
        phx-hook="MCPFormModal"
        data-close-event="hide_create"
      >
        <:title>New MCP Server</:title>
        <:body>
          <div
            :if={@modal_error}
            role="alert"
            aria-live="polite"
            class="mb-4 rounded-lg border border-error bg-error-container p-3 text-sm text-on-error-container"
          >
            {@modal_error}
          </div>
          <.react_form
            for={%{}}
            id="mcp-create-form"
            class="space-y-4"
            values={@custom_form}
            draft={react_form_draft(assigns, "mcp-create-form")}
            structure={
              {@custom_provider, @custom_transport,
               Enum.map(@source_providers, &{&1.id, &1.name, &1.enabled})}
            }
            phx-submit="create_config"
            phx-change="change_custom_config"
          >
            <.dm_react_field
              type="select"
              name="provider_id"
              label="Provider"
              options={[
                %{value: "", label: "Custom configuration"}
                | Enum.map(@source_providers, &%{value: &1.id, label: &1.name})
              ]}
            />
            <div :if={@custom_provider != ""} class="space-y-4">
              <p class="text-sm text-on-surface-variant">
                Uses the selected provider's MCP endpoint and credentials.
                Leave the URL blank to use its default MCP endpoint.
              </p>
              <.dm_input
                type="text"
                id="mcp-create-provider-url"
                name="url"
                value={form_value(@custom_form, "url")}
                placeholder="Optional custom MCP endpoint"
                label="MCP URL override (optional)"
              />
            </div>
            <div :if={@custom_provider == ""} class="space-y-4">
              <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 - preserve required, placeholders and textarea layout attributes. --%>
              <.dm_input
                type="text"
                id="mcp-create-name"
                autofocus
                name="name"
                value={form_value(@custom_form, "name")}
                placeholder="Server name"
                required
                label="Name"
              />
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
              <div :if={@custom_transport in ["streamable_http", "sse"]} class="space-y-4">
                <.dm_input
                  type="text"
                  id="mcp-create-url"
                  name="url"
                  required
                  value={form_value(@custom_form, "url")}
                  placeholder="http://localhost:7331/mcp"
                  label="URL"
                />
                <.dm_textarea
                  id="mcp-create-headers"
                  name="headers"
                  value={form_value(@custom_form, "headers")}
                  rows={4}
                  placeholder="Authorization: Bearer token"
                  label="Headers (Name: Value, one per line)"
                />
              </div>
              <div :if={@custom_transport == "stdio"} class="space-y-4">
                <.dm_input
                  type="text"
                  id="mcp-create-command"
                  name="command"
                  required
                  value={form_value(@custom_form, "command")}
                  placeholder="e.g. npx"
                  label="Command"
                />
                <.dm_textarea
                  id="mcp-create-args"
                  name="args"
                  value={form_value(@custom_form, "args")}
                  rows={3}
                  placeholder="One argument per line"
                  label="Arguments (one per line)"
                />
                <.dm_textarea
                  id="mcp-create-env"
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
                  id="mcp-create-enabled"
                  name="enabled"
                  value="true"
                  label="Enabled"
                />
              </div>
            </div>
            <:actions>
              <.dm_btn type="button" variant="ghost" phx-click="hide_create">Cancel</.dm_btn>
              <%!-- # TODO(upstream): duskmoon-dev/duskmoon-elements#88 - remove after reconnect-safe button listeners ship.
                   # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#88 - native submission avoids duplicate requests after validation. --%>
              <.dm_btn type="submit" native_submit variant="primary">
                Add MCP Server
              </.dm_btn>
            </:actions>
          </.react_form>
        </:body>
      </.dm_modal>

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
            >
              <:trigger :let={dialog_id}>
                <.dm_btn
                  variant="ghost"
                  size="xs"
                  class="text-primary"
                  command="show-modal"
                  commandfor={dialog_id}
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

      <div :if={@configs == []} class="text-center text-on-surface-variant py-12">
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

  defp modal_error(socket, message) do
    socket |> assign(modal_error: message) |> put_flash(:error, message)
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
