defmodule SynapsisWeb.MemorySettingsLive.Index do
  use SynapsisWeb, :live_view
  alias Synapsis.Memory.Settings

  @impl true
  def mount(_params, _session, socket) do
    case Settings.get() do
      {:ok, config} ->
        {:ok, assign(socket, page_title: "Memory settings", config: config)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(page_title: "Memory settings", config: nil)
         |> put_flash(
           :error,
           "Memory configuration is unavailable or invalid. Host memory is disabled."
         )}
    end
  end

  @impl true
  def handle_event("save", %{"memory" => values}, socket) do
    config = %{
      "backend" => "workspace",
      "host_agent" => %{
        "enabled" => values["enabled"] == "true",
        "endpoint" => values["endpoint"],
        "agent_id" => values["agent_id"]
      }
    }

    case Settings.save(config) do
      {:ok, saved} ->
        {:noreply, socket |> assign(config: saved) |> put_flash(:info, "Memory settings saved")}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Unable to save memory settings. Check the local endpoint and agent ID."
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_layout current_path="/settings/memory" content_class="max-w-3xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Memory</:crumb>
      </.breadcrumb>
      <.dm_card variant="bordered">
        <:title>Memory configuration</:title>
        <div class="space-y-4">
          <div>
            <h2 class="font-semibold">Workspace Markdown</h2>
            <p class="text-sm text-on-surface-variant">
              Default memory is stored in each agent workspace: MEMORY.md and memory/**/*.md.
            </p>
            <.dm_link navigate={~p"/agent/memory"}>View memory in Agent</.dm_link>
          </div>
          <.form for={%{}} id="memory-settings-form" phx-submit="save">
            <h2 class="font-semibold mb-2">Backplane host agent</h2>
            <p class="text-sm text-on-surface-variant mb-3">
              Optional host memory is disabled by default. Saving these settings does not contact the host.
            </p>
            <div class="space-y-3">
              <label class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="memory[enabled]"
                  value="true"
                  checked={@config && @config["host_agent"]["enabled"]}
                /> Enable host agent memory
              </label>
              <div>
                <label for="memory-endpoint" class="label">Local endpoint</label>
                <.dm_input
                  id="memory-endpoint"
                  name="memory[endpoint]"
                  value={(@config && @config["host_agent"]["endpoint"]) || "http://127.0.0.1:4222"}
                  required
                />
              </div>
              <div>
                <label for="memory-agent-id" class="label">Host agent ID</label>
                <.dm_input
                  id="memory-agent-id"
                  name="memory[agent_id]"
                  value={(@config && @config["host_agent"]["agent_id"]) || "synapsis"}
                  required
                />
              </div>
              <p class="text-xs text-on-surface-variant">
                Host memory uses the host account’s memory. Agent ID selects a host route; it does not create a separate memory space.
              </p>
              <.dm_btn type="submit" variant="primary">Save settings</.dm_btn>
            </div>
          </.form>
        </div>
      </.dm_card>
    </.settings_layout>
    """
  end
end
