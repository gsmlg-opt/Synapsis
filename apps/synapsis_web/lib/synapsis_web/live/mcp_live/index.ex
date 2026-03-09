defmodule SynapsisWeb.MCPLive.Index do
  use SynapsisWeb, :live_view

  alias Synapsis.{Repo, PluginConfig}
  import Ecto.Query, only: [from: 2]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, configs: [], page_title: "MCP Servers")}
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
      SynapsisPlugin.MCP.Presets.all()
      |> Enum.find(&(&1.name == name))

    {:noreply, assign(socket, selected_preset: preset)}
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

    {:noreply, assign(socket, selected_preset: custom)}
  end

  def handle_event("back_to_presets", _params, socket) do
    {:noreply, assign(socket, selected_preset: nil)}
  end

  def handle_event("create_config", params, socket) do
    preset = socket.assigns.selected_preset

    attrs = %{
      type: "mcp",
      name: params["name"] || preset.name,
      transport: params["transport"] || preset.transport,
      command: params["command"] || preset.command,
      args: if(params["args"], do: parse_args(params["args"]), else: preset.args),
      env: if(params["env"], do: parse_env(params["env"]), else: preset.env),
      auto_start: params["auto_start"] == "true"
    }

    case Repo.insert(PluginConfig.changeset(%PluginConfig{}, attrs)) do
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
    case Repo.get(PluginConfig, id) do
      nil ->
        {:noreply, socket}

      config ->
        config
        |> PluginConfig.changeset(%{auto_start: !config.auto_start})
        |> Repo.update()

        {:noreply, assign(socket, configs: list_configs())}
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
    Repo.all(from(p in PluginConfig, where: p.type == "mcp", order_by: [asc: p.name]))
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
    presets = SynapsisPlugin.MCP.Presets.all()
    configured = Enum.map(assigns.configs, & &1.name)

    assigns =
      assign(assigns,
        presets: presets,
        configured_names: configured
      )

    ~H"""
    <div class="max-w-5xl mx-auto p-6">
      <.dm_breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>MCP Servers</:crumb>
      </.dm_breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">MCP Servers</h1>
        <.dm_link
          :if={!@show_form}
          navigate={~p"/settings/mcp/new"}
        >
          <.dm_btn variant="primary" size="sm">+ Add MCP Server</.dm_btn>
        </.dm_link>
      </div>

      <.dm_flash_group flash={@flash} />

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
            <.dm_form for={%{}} phx-submit="create_config">
              <%= if Map.get(@selected_preset, :custom) do %>
                <.dm_input
                  type="text"
                  name="name"
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
                  options={[{"stdio", "stdio"}, {"sse", "SSE"}]}
                />
              <% else %>
                <.readonly_field label="Transport" value={@selected_preset.transport} />
              <% end %>
              <%= if Map.get(@selected_preset, :custom) do %>
                <.dm_input
                  type="text"
                  name="command"
                  placeholder="e.g. npx"
                  label="Command"
                />
              <% else %>
                <.dm_input
                  type="text"
                  name="command"
                  value={@selected_preset.command}
                  readonly
                  label="Command"
                />
              <% end %>
              <%= if Map.get(@selected_preset, :custom) do %>
                <.dm_textarea
                  name="args"
                  rows={3}
                  placeholder="One argument per line"
                  label="Arguments (one per line)"
                />
              <% else %>
                <.readonly_field
                  label="Arguments (one per line)"
                  value={Enum.join(@selected_preset.args, "\n")}
                  monospace
                />
              <% end %>
              <div :if={Map.get(@selected_preset, :custom) || map_size(@selected_preset.env) > 0}>
                <.dm_textarea
                  name="env"
                  rows={3}
                  placeholder="KEY=VALUE"
                  label="Environment Variables (KEY=VALUE, one per line)"
                  value={format_env_for_form(@selected_preset.env)}
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
                class="text-base-content/50 hover:text-base-content text-sm"
              >
                Cancel
              </.dm_link>
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <button
                :for={preset <- @presets}
                phx-click="select_preset"
                phx-value-name={preset.name}
                disabled={preset.name in @configured_names}
                class="w-full text-left"
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
                  <div class="text-xs text-base-content/50 mt-1">{preset.description}</div>
                  <div class="text-xs text-base-content/40 mt-1 font-mono">
                    {preset.command} {Enum.join(preset.args, " ")}
                  </div>
                  <div
                    :if={preset.name in @configured_names}
                    class="text-xs text-base-content/40 mt-1"
                  >
                    Already configured
                  </div>
                </.dm_card>
              </button>
            </div>

            <h3 class="text-sm font-semibold text-base-content/50 mt-6 mb-3">Custom</h3>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <button phx-click="select_custom" class="w-full text-left">
                <.dm_card variant="bordered" class="cursor-pointer border-dashed hover:border-primary">
                  <div class="font-medium">Custom MCP Server</div>
                  <div class="text-xs text-base-content/50 mt-1">
                    Configure a custom stdio or SSE server
                  </div>
                </.dm_card>
              </button>
            </div>
          </div>
        <% end %>
      <% end %>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.dm_card
          :for={config <- @configs}
          variant="bordered"
        >
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
          <div class="text-xs text-base-content/50">
            {config.transport}
            <span :if={config.command}>{" | #{config.command}"}</span>
            <span :if={config.args != []}>
              {" " <> Enum.join(config.args, " ")}
            </span>
          </div>
          <div :if={config.url} class="text-xs text-base-content/40 mt-1 truncate">
            {config.url}
          </div>
          <div :if={map_size(config.env || %{}) > 0} class="text-xs text-warning mt-1">
            {"#{map_size(config.env)} env var(s)"}
          </div>
          <div class="mt-2">
            <.dm_badge :if={config.auto_start} color="success" size="sm">
              Enabled
            </.dm_badge>
            <.dm_badge :if={!config.auto_start} color="ghost" size="sm">
              Disabled
            </.dm_badge>
          </div>
        </.dm_card>
      </div>

      <div :if={@configs == [] && !@show_form} class="text-center text-base-content/40 py-12">
        No MCP servers configured. Click "+ Add MCP Server" to get started.
      </div>
    </div>
    """
  end

  defp format_env_for_form(env) when is_map(env) and map_size(env) > 0 do
    env |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_env_for_form(_), do: ""

  defp has_required_env?(%{env: env}) when is_map(env) do
    Enum.any?(env, fn {_k, v} -> v == "" end)
  end

  defp has_required_env?(_), do: false
end
