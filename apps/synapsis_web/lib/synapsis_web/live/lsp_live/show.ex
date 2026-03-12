defmodule SynapsisWeb.LSPLive.Show do
  use SynapsisWeb, :live_view

  alias Synapsis.{Repo, PluginConfig}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Repo.get(PluginConfig, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "LSP server not found")
         |> push_navigate(to: ~p"/settings/lsp")}

      %PluginConfig{type: "lsp"} = config ->
        {:ok, assign(socket, config: config, page_title: config.name)}

      _other ->
        {:ok,
         socket
         |> put_flash(:error, "Not an LSP configuration")
         |> push_navigate(to: ~p"/settings/lsp")}
    end
  end

  @impl true
  def handle_event("update_config", params, socket) do
    attrs = %{
      command: params["command"],
      root_path: params["root_path"],
      auto_start: params["auto_start"] == "true"
    }

    changeset = PluginConfig.changeset(socket.assigns.config, attrs)

    case Repo.update(changeset) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(config: config)
         |> put_flash(:info, "LSP server updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/lsp"}>LSP Servers</:crumb>
        <:crumb>{@config.name}</:crumb>
      </.breadcrumb>

      <h1 class="text-2xl font-bold mb-6">{@config.name}</h1>

      <.dm_card variant="bordered">
        <.dm_form for={%{}} phx-submit="update_config">
          <.dm_input
            type="text"
            name="command"
            value={@config.command}
            label="Command"
          />

          <.readonly_field label="Args" value={Enum.join(@config.args || [], " ")} />

          <.dm_input
            type="text"
            name="root_path"
            value={@config.root_path}
            label="Root Path"
          />

          <div>
            <input type="hidden" name="auto_start" value="false" />
            <.dm_checkbox
              name="auto_start"
              value="true"
              checked={@config.auto_start}
              label="Auto-start"
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
