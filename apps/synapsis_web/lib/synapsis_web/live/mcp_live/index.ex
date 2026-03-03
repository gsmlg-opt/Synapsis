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
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-5xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">MCP Servers</span>
        </div>

        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">MCP Servers</h1>
          <.link
            :if={!@show_form}
            navigate={~p"/settings/mcp/new"}
            class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + Add MCP Server
          </.link>
        </div>

        <.flash_group flash={@flash} />

        <%= if @show_form do %>
          <%= if @selected_preset do %>
            <div class="mb-6 bg-gray-900 rounded-lg p-6 border border-gray-800">
              <div class="flex items-center gap-3 mb-4">
                <button
                  phx-click="back_to_presets"
                  class="text-gray-400 hover:text-gray-200 text-sm"
                >
                  &larr; Back
                </button>
                <h2 class="text-lg font-semibold">
                  <%= if Map.get(@selected_preset, :custom) do %>
                    New Custom MCP Server
                  <% else %>
                    Add {@selected_preset.name}
                  <% end %>
                </h2>
              </div>
              <form phx-submit="create_config" class="space-y-3">
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Name</label>
                  <%= if Map.get(@selected_preset, :custom) do %>
                    <input
                      type="text"
                      name="name"
                      placeholder="Server name"
                      required
                      class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
                    />
                  <% else %>
                    <div class="bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700">
                      {@selected_preset.name}
                    </div>
                  <% end %>
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Transport</label>
                  <%= if Map.get(@selected_preset, :custom) do %>
                    <select
                      name="transport"
                      class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
                    >
                      <option value="stdio">stdio</option>
                      <option value="sse">SSE</option>
                    </select>
                  <% else %>
                    <div class="bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700">
                      {@selected_preset.transport}
                    </div>
                  <% end %>
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Command</label>
                  <%= if Map.get(@selected_preset, :custom) do %>
                    <input
                      type="text"
                      name="command"
                      placeholder="e.g. npx"
                      class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
                    />
                  <% else %>
                    <input
                      type="text"
                      name="command"
                      value={@selected_preset.command}
                      readonly
                      class="w-full bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700"
                    />
                  <% end %>
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Arguments (one per line)</label>
                  <%= if Map.get(@selected_preset, :custom) do %>
                    <textarea
                      name="args"
                      rows="3"
                      placeholder="One argument per line"
                      class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none font-mono text-sm"
                    ></textarea>
                  <% else %>
                    <div class="bg-gray-800 text-gray-400 rounded px-3 py-2 border border-gray-700 font-mono text-sm whitespace-pre-wrap">
                      {Enum.join(@selected_preset.args, "\n")}
                    </div>
                  <% end %>
                </div>
                <div :if={Map.get(@selected_preset, :custom) || map_size(@selected_preset.env) > 0}>
                  <label class="block text-xs text-gray-500 mb-1">
                    Environment Variables (KEY=VALUE, one per line)
                  </label>
                  <textarea
                    name="env"
                    rows="3"
                    placeholder="KEY=VALUE"
                    class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none font-mono text-sm"
                  ><%= format_env_for_form(@selected_preset.env) %></textarea>
                  <div
                    :if={!Map.get(@selected_preset, :custom) && has_required_env?(@selected_preset)}
                    class="text-xs text-yellow-500 mt-1"
                  >
                    Fill in the required environment variable values above
                  </div>
                </div>
                <div>
                  <label class="flex items-center gap-2">
                    <input type="hidden" name="auto_start" value="false" />
                    <input
                      type="checkbox"
                      name="auto_start"
                      value="true"
                      class="rounded bg-gray-800 border-gray-700"
                    />
                    <span class="text-sm">Auto-start on startup</span>
                  </label>
                </div>
                <button
                  type="submit"
                  class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
                >
                  Add MCP Server
                </button>
              </form>
            </div>
          <% else %>
            <div class="mb-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="text-lg font-semibold">Select an MCP Server</h2>
                <.link
                  navigate={~p"/settings/mcp"}
                  class="text-gray-400 hover:text-gray-200 text-sm"
                >
                  Cancel
                </.link>
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                <button
                  :for={preset <- @presets}
                  phx-click="select_preset"
                  phx-value-name={preset.name}
                  disabled={preset.name in @configured_names}
                  class={[
                    "w-full text-left rounded-lg p-4 border transition-colors",
                    if(preset.name in @configured_names,
                      do:
                        "bg-gray-900/50 border-gray-800 text-gray-600 cursor-not-allowed opacity-50",
                      else:
                        "bg-gray-900 border-gray-800 hover:border-blue-500 hover:bg-gray-800 cursor-pointer"
                    )
                  ]}
                >
                  <div class="font-medium">{preset.name}</div>
                  <div class="text-xs text-gray-500 mt-1">{preset.description}</div>
                  <div class="text-xs text-gray-600 mt-1 font-mono">
                    {preset.command} {Enum.join(preset.args, " ")}
                  </div>
                  <div :if={preset.name in @configured_names} class="text-xs text-gray-600 mt-1">
                    Already configured
                  </div>
                </button>
              </div>

              <h3 class="text-sm font-semibold text-gray-400 mt-6 mb-3">Custom</h3>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                <button
                  phx-click="select_custom"
                  class="w-full text-left bg-gray-900 rounded-lg p-4 border border-dashed border-gray-700 hover:border-blue-500 hover:bg-gray-800 transition-colors cursor-pointer"
                >
                  <div class="font-medium">Custom MCP Server</div>
                  <div class="text-xs text-gray-500 mt-1">Configure a custom stdio or SSE server</div>
                </button>
              </div>
            </div>
          <% end %>
        <% end %>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <div
            :for={config <- @configs}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800"
          >
            <div class="flex justify-between items-start mb-2">
              <.link
                navigate={~p"/settings/mcp/#{config.id}"}
                class="font-medium hover:text-blue-400 transition-colors"
              >
                {config.name}
              </.link>
              <div class="flex items-center gap-2">
                <button
                  phx-click="toggle_enabled"
                  phx-value-id={config.id}
                  class={[
                    "relative inline-flex h-5 w-9 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                    if(config.auto_start, do: "bg-blue-600", else: "bg-gray-700")
                  ]}
                  title={if(config.auto_start, do: "Enabled — click to disable", else: "Disabled — click to enable")}
                >
                  <span class={[
                    "pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                    if(config.auto_start, do: "translate-x-4", else: "translate-x-0")
                  ]} />
                </button>
                <button
                  phx-click="delete_config"
                  phx-value-id={config.id}
                  data-confirm="Delete this MCP server?"
                  class="text-gray-600 hover:text-red-400 text-sm ml-1"
                >
                  Delete
                </button>
              </div>
            </div>
            <div class="text-xs text-gray-500">
              {config.transport}
              <span :if={config.command}>{" | #{config.command}"}</span>
              <span :if={config.args != []}>
                {" " <> Enum.join(config.args, " ")}
              </span>
            </div>
            <div :if={config.url} class="text-xs text-gray-600 mt-1 truncate">
              {config.url}
            </div>
            <div :if={map_size(config.env || %{}) > 0} class="text-xs text-yellow-600 mt-1">
              {"#{map_size(config.env)} env var(s)"}
            </div>
            <div class="mt-2">
              <span
                :if={config.auto_start}
                class="inline-block text-xs px-2 py-0.5 rounded bg-green-900/50 text-green-400"
              >
                Enabled
              </span>
              <span
                :if={!config.auto_start}
                class="inline-block text-xs px-2 py-0.5 rounded bg-gray-800 text-gray-500"
              >
                Disabled
              </span>
            </div>
          </div>
        </div>

        <div :if={@configs == [] && !@show_form} class="text-center text-gray-600 py-12">
          No MCP servers configured. Click "+ Add MCP Server" to get started.
        </div>
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
