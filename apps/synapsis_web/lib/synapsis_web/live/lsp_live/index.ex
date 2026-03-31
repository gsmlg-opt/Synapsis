defmodule SynapsisWeb.LSPLive.Index do
  use SynapsisWeb, :live_view
  require Logger

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
     apply_action(socket, socket.assigns.live_action, params)
     |> assign(configs: configs)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, show_custom_form: true, show_import: false)
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_custom_form: false, show_import: false)
  end

  # -- Import JSON -------------------------------------------------------------

  @impl true
  def handle_event("show_import", _params, socket) do
    {:noreply, assign(socket, show_import: true)}
  end

  def handle_event("hide_import", _params, socket) do
    {:noreply, assign(socket, show_import: false)}
  end

  def handle_event("import_json", %{"json" => json}, socket) do
    case parse_lsp_json(json) do
      {:ok, servers} when map_size(servers) == 0 ->
        {:noreply, put_flash(socket, :error, "No LSP servers found in JSON")}

      {:ok, servers} ->
        configured = Enum.map(socket.assigns.configs, & &1.name) |> MapSet.new()
        {imported, skipped} = import_lsp_servers(servers, configured)

        msg =
          case {imported, skipped} do
            {0, s} -> "No new servers imported (#{s} already configured)"
            {i, 0} -> "Imported #{i} LSP server(s)"
            {i, s} -> "Imported #{i} LSP server(s), skipped #{s} already configured"
          end

        {:noreply,
         socket
         |> assign(show_import: false, configs: list_configs())
         |> put_flash(:info, msg)}

      {:error, reason} ->
        Logger.warning("lsp_import_invalid_json", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Invalid JSON format")}
    end
  end

  # -- Enable / Disable built-in -----------------------------------------------

  def handle_event("enable_builtin", %{"name" => name}, socket) do
    preset = SynapsisPlugin.LSP.Presets.get(name)

    if preset do
      attrs = %{
        type: "lsp",
        name: preset.name,
        command: preset.command,
        args: preset.args,
        auto_start: true
      }

      case Repo.insert(PluginConfig.changeset(%PluginConfig{}, attrs)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(configs: list_configs())
           |> put_flash(:info, "#{preset.name} LSP enabled")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to enable #{preset.name}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("disable_builtin", %{"name" => name}, socket) do
    case Repo.get_by(PluginConfig, name: name, type: "lsp") do
      nil ->
        {:noreply, socket}

      config ->
        case Repo.delete(config) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(configs: list_configs())
             |> put_flash(:info, "#{name} LSP disabled")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to disable #{name}")}
        end
    end
  end

  def handle_event("toggle_auto_start", %{"id" => id}, socket) do
    case Repo.get(PluginConfig, id) do
      nil ->
        {:noreply, socket}

      config ->
        case config
             |> PluginConfig.changeset(%{auto_start: !config.auto_start})
             |> Repo.update() do
          {:ok, _} -> {:noreply, assign(socket, configs: list_configs())}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update config")}
        end
    end
  end

  # -- Custom LSP add ----------------------------------------------------------

  def handle_event("create_custom", params, socket) do
    attrs = %{
      type: "lsp",
      name: params["name"],
      command: params["command"],
      args: parse_args(params["args"]),
      env: parse_env(params["env"]),
      auto_start: params["auto_start"] == "true"
    }

    case Repo.insert(PluginConfig.changeset(%PluginConfig{}, attrs)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(configs: list_configs(), show_custom_form: false)
         |> put_flash(:info, "Custom LSP server added")
         |> push_navigate(to: ~p"/settings/lsp")}

      {:error, %Ecto.Changeset{errors: errors}} ->
        msg =
          case Keyword.get(errors, :name) do
            {"has already been taken", _} -> "Name already taken"
            _ -> "Failed to add LSP server"
          end

        {:noreply, put_flash(socket, :error, msg)}

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
    # Note: delete failure here is non-critical — list refresh shows current state
  end

  # -- Helpers -----------------------------------------------------------------

  defp list_configs do
    Repo.all(from(p in PluginConfig, where: p.type == "lsp", order_by: [asc: p.name]))
  end

  defp parse_lsp_json(json) do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) ->
        servers =
          Enum.filter(data, fn {_k, v} ->
            is_map(v) and is_binary(Map.get(v, "command", nil))
          end)
          |> Map.new()

        {:ok, servers}

      {:ok, _} ->
        {:error, "expected a JSON object"}

      {:error, %Jason.DecodeError{}} ->
        {:error, "invalid JSON format"}
    end
  end

  defp import_lsp_servers(servers, configured) do
    Enum.reduce(servers, {0, 0}, fn {name, config}, {imported, skipped} ->
      if MapSet.member?(configured, name) do
        {imported, skipped + 1}
      else
        attrs = %{
          type: "lsp",
          name: name,
          command: Map.get(config, "command", ""),
          args: Map.get(config, "args", []),
          env: Map.get(config, "env", %{}),
          settings: Map.get(config, "settings", %{}),
          auto_start: Map.get(config, "autoStart", false)
        }

        case Repo.insert(PluginConfig.changeset(%PluginConfig{}, attrs)) do
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

  # -- Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    presets = SynapsisPlugin.LSP.Presets.all()
    configured_map = Map.new(assigns.configs, &{&1.name, &1})

    custom_configs =
      Enum.reject(assigns.configs, fn c -> SynapsisPlugin.LSP.Presets.builtin?(c.name) end)

    assigns =
      assign(assigns,
        presets: presets,
        configured_map: configured_map,
        custom_configs: custom_configs
      )

    ~H"""
    <div class="max-w-5xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>LSP Servers</:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">LSP Servers</h1>
        <div class="flex gap-2">
          <.dm_btn variant="ghost" size="sm" phx-click="show_import">
            <.dm_mdi name="code-json" class="w-4 h-4 mr-1" /> Import JSON
          </.dm_btn>
          <.dm_link navigate={~p"/settings/lsp/new"}>
            <.dm_btn variant="ghost" size="sm">+ Custom LSP</.dm_btn>
          </.dm_link>
        </div>
      </div>

      <%!-- Import JSON form --%>
      <.dm_card :if={@show_import} variant="bordered" class="mb-6">
        <div class="flex items-center gap-3 mb-4">
          <.dm_btn variant="ghost" size="sm" phx-click="hide_import">
            &larr; Back
          </.dm_btn>
          <h2 class="text-lg font-semibold">Import LSP Servers from JSON</h2>
        </div>
        <p class="text-sm text-base-content/60 mb-3">
          Paste JSON in Claude Code format. Each key is the server name, value is the config.
        </p>
        <details class="mb-3">
          <summary class="text-xs text-base-content/40 cursor-pointer hover:text-base-content/60">
            Example format
          </summary>
          <pre class="text-xs bg-base-200 p-3 rounded mt-1 overflow-x-auto"><code>{lsp_import_example()}</code></pre>
        </details>
        <.dm_form for={%{}} phx-submit="import_json">
          <.dm_textarea
            name="json"
            value=""
            rows={10}
            placeholder={lsp_import_placeholder()}
            label="JSON"
          />
          <div class="flex gap-2 mt-3">
            <.dm_btn type="submit" variant="primary">Import</.dm_btn>
            <.dm_btn type="button" variant="ghost" phx-click="hide_import">Cancel</.dm_btn>
          </div>
        </.dm_form>
      </.dm_card>

      <%!-- Custom LSP form --%>
      <.dm_card :if={@show_custom_form} variant="bordered" class="mb-6">
        <div class="flex items-center gap-3 mb-4">
          <.dm_link navigate={~p"/settings/lsp"}>
            <.dm_btn variant="ghost" size="sm">&larr; Back</.dm_btn>
          </.dm_link>
          <h2 class="text-lg font-semibold">Add Custom LSP Server</h2>
        </div>
        <.dm_form for={%{}} phx-submit="create_custom">
          <.dm_input
            type="text"
            name="name"
            value=""
            placeholder="e.g. my-language"
            required
            label="Name"
          />
          <.dm_input
            type="text"
            name="command"
            value=""
            placeholder="e.g. my-language-server"
            required
            label="Command"
          />
          <.dm_textarea
            name="args"
            value=""
            rows={2}
            placeholder="One argument per line"
            label="Arguments (one per line)"
          />
          <.dm_textarea
            name="env"
            value=""
            rows={2}
            placeholder="KEY=VALUE"
            label="Environment Variables (KEY=VALUE, one per line)"
          />
          <div>
            <input type="hidden" name="auto_start" value="false" />
            <.dm_checkbox name="auto_start" value="true" label="Auto-start on startup" />
          </div>
          <.dm_btn type="submit" variant="primary">Add LSP Server</.dm_btn>
        </.dm_form>
      </.dm_card>

      <%!-- Built-in LSP servers --%>
      <h2 class="text-lg font-semibold mb-3">Built-in Language Servers</h2>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 mb-8">
        <.dm_card :for={preset <- @presets} variant="bordered">
          <% config = Map.get(@configured_map, preset.name) %>
          <% enabled = config != nil %>
          <div class="flex justify-between items-start mb-2">
            <div>
              <div class="font-medium flex items-center gap-2">
                {preset.name}
                <.dm_badge :if={enabled} variant="success" size="sm">Enabled</.dm_badge>
                <.dm_badge :if={!enabled} variant="ghost" size="sm">Disabled</.dm_badge>
              </div>
              <div class="text-xs text-base-content/50 mt-1">{preset.description}</div>
            </div>
          </div>
          <div class="text-xs text-base-content/40 font-mono mt-1">
            {preset.command} {Enum.join(preset.args, " ")}
          </div>
          <div class="text-xs text-base-content/40 mt-1">
            {preset.extensions |> Enum.join(", ")}
          </div>
          <div class="mt-3 flex items-center gap-2 flex-wrap">
            <%= if enabled do %>
              <.dm_switch
                name={"auto_start_#{config.id}"}
                checked={config.auto_start}
                phx-click="toggle_auto_start"
                phx-value-id={config.id}
              />
              <span class="text-xs text-base-content/50">Auto-start</span>
              <.dm_link navigate={~p"/settings/lsp/#{config.id}"} class="ml-auto">
                <.dm_btn variant="ghost" size="xs">Edit</.dm_btn>
              </.dm_link>
              <.dm_btn
                variant="ghost"
                size="xs"
                class="text-error"
                phx-click="disable_builtin"
                phx-value-name={preset.name}
                confirm={"Disable #{preset.name} LSP?"}
              >
                Disable
              </.dm_btn>
            <% else %>
              <.dm_btn
                variant="primary"
                size="xs"
                phx-click="enable_builtin"
                phx-value-name={preset.name}
              >
                Enable
              </.dm_btn>
            <% end %>
          </div>
        </.dm_card>
      </div>

      <%!-- Custom LSP servers --%>
      <div :if={@custom_configs != []}>
        <h2 class="text-lg font-semibold mb-3">Custom Language Servers</h2>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          <.dm_card :for={config <- @custom_configs} variant="bordered">
            <div class="flex justify-between items-start mb-2">
              <.dm_link
                navigate={~p"/settings/lsp/#{config.id}"}
                class="font-medium hover:text-primary transition-colors"
              >
                {config.name}
              </.dm_link>
              <.dm_btn
                variant="ghost"
                size="xs"
                class="text-error hover:text-error/80 ml-2"
                confirm="Delete this LSP server?"
                phx-click="delete_config"
                phx-value-id={config.id}
              >
                Delete
              </.dm_btn>
            </div>
            <div class="text-xs text-base-content/50">{config.command}</div>
            <div :if={config.args != []} class="text-xs text-base-content/40 mt-1">
              {Enum.join(config.args, " ")}
            </div>
            <div class="mt-2 flex items-center gap-2">
              <.dm_switch
                name={"auto_start_#{config.id}"}
                checked={config.auto_start}
                phx-click="toggle_auto_start"
                phx-value-id={config.id}
              />
              <span class="text-xs text-base-content/50">Auto-start</span>
            </div>
          </.dm_card>
        </div>
      </div>
    </div>
    """
  end

  defp lsp_import_example do
    Jason.encode!(
      %{
        "gopls" => %{"command" => "gopls"},
        "typescript" => %{"command" => "typescript-language-server", "args" => ["--stdio"]}
      },
      pretty: true
    )
  end

  defp lsp_import_placeholder do
    ~s|{"gopls": {"command": "gopls"}, "typescript": {"command": "typescript-language-server", "args": ["--stdio"]}}|
  end
end
