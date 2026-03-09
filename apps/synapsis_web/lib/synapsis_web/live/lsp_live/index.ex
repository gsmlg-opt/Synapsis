defmodule SynapsisWeb.LSPLive.Index do
  use SynapsisWeb, :live_view

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
      SynapsisPlugin.LSP.Presets.all()
      |> Enum.find(&(&1.name == name))

    {:noreply, assign(socket, selected_preset: preset)}
  end

  def handle_event("back_to_presets", _params, socket) do
    {:noreply, assign(socket, selected_preset: nil)}
  end

  def handle_event("create_config", params, socket) do
    preset = socket.assigns.selected_preset

    attrs = %{
      type: "lsp",
      name: preset.name,
      command: params["command"] || preset.command,
      args: preset.args,
      auto_start: params["auto_start"] == "true"
    }

    case Repo.insert(PluginConfig.changeset(%PluginConfig{}, attrs)) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(configs: list_configs(), show_form: false, selected_preset: nil)
         |> put_flash(:info, "LSP server added")
         |> push_navigate(to: ~p"/settings/lsp")}

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
  end

  defp list_configs do
    Repo.all(from(p in PluginConfig, where: p.type == "lsp", order_by: [asc: p.name]))
  end

  @impl true
  def render(assigns) do
    presets = SynapsisPlugin.LSP.Presets.all()
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
        <:crumb>LSP Servers</:crumb>
      </.dm_breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">LSP Servers</h1>
        <.dm_link
          :if={!@show_form}
          navigate={~p"/settings/lsp/new"}
        >
          <.dm_btn variant="primary" size="sm">+ Add LSP Server</.dm_btn>
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
              <h2 class="text-lg font-semibold">Add {@selected_preset.name} LSP</h2>
            </div>
            <.dm_form for={%{}} phx-submit="create_config">
              <.readonly_field label="Language" value={@selected_preset.name} />
              <.dm_input
                type="text"
                name="command"
                value={@selected_preset.command}
                readonly
                label="Command"
              />
              <.readonly_field label="Args" value={Enum.join(@selected_preset.args, " ")} />
              <div>
                <input type="hidden" name="auto_start" value="false" />
                <.dm_checkbox
                  name="auto_start"
                  value="true"
                  label="Auto-start"
                />
              </div>
              <.dm_btn type="submit" variant="primary">
                Add LSP Server
              </.dm_btn>
            </.dm_form>
          </.dm_card>
        <% else %>
          <div class="mb-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold">Select a Language Server</h2>
              <.dm_link
                navigate={~p"/settings/lsp"}
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
                  <div class="text-xs text-base-content/50 mt-1">{preset.command}</div>
                  <div
                    :if={preset.name in @configured_names}
                    class="text-xs text-base-content/40 mt-1"
                  >
                    Already configured
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
          <div class="mt-2">
            <.dm_badge :if={config.auto_start} color="success" size="sm">
              Auto-start
            </.dm_badge>
            <.dm_badge :if={!config.auto_start} color="ghost" size="sm">
              Manual
            </.dm_badge>
          </div>
        </.dm_card>
      </div>

      <div :if={@configs == [] && !@show_form} class="text-center text-base-content/40 py-12">
        No LSP servers configured. Click "+ Add LSP Server" to get started.
      </div>
    </div>
    """
  end
end
