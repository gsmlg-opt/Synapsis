defmodule SynapsisWeb.SessionLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    case Synapsis.Projects.get(project_id) do
      {:ok, project} ->
        sessions = Synapsis.Sessions.list_by_project(project.id)
        {:ok, providers} = Synapsis.Providers.list(enabled: true)

        {:ok,
         assign(socket,
           project: project,
           sessions: sessions,
           providers: providers,
           page_title: "Sessions",
           show_new_session_form: false,
           new_session_provider: if(providers != [], do: hd(providers).name, else: "anthropic"),
           new_session_model: Synapsis.Providers.default_model("anthropic")
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Project not found")
         |> push_navigate(to: ~p"/projects")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_new_session_form", _params, socket) do
    {:noreply, assign(socket, show_new_session_form: !socket.assigns.show_new_session_form)}
  end

  def handle_event("select_provider", %{"provider" => provider_name}, socket) do
    provider = Enum.find(socket.assigns.providers, &(&1.name == provider_name))
    type = if provider, do: provider.type, else: provider_name
    default_model = Synapsis.Providers.default_model(type)

    {:noreply,
     assign(socket, new_session_provider: provider_name, new_session_model: default_model)}
  end

  def handle_event("select_model", %{"value" => model}, socket) do
    {:noreply, assign(socket, new_session_model: model)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, new_session_model: model)}
  end

  def handle_event("create_session", _params, socket) do
    opts = %{
      provider: socket.assigns.new_session_provider,
      model: socket.assigns.new_session_model
    }

    case Synapsis.Sessions.create(socket.assigns.project.path, opts) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(show_new_session_form: false)
         |> push_navigate(to: ~p"/projects/#{socket.assigns.project.id}/sessions/#{session.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/projects"} class="hover:text-gray-300">Projects</.link>
          <span>/</span>
          <.link navigate={~p"/projects/#{@project.id}"} class="hover:text-gray-300">
            {@project.slug}
          </.link>
          <span>/</span>
          <span class="text-gray-300">Sessions</span>
        </div>

        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">Sessions</h1>
          <button
            phx-click="toggle_new_session_form"
            class="px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + New Session
          </button>
        </div>

        <div
          :if={@show_new_session_form}
          class="mb-6 bg-gray-900 rounded-lg p-4 border border-gray-800 space-y-3"
        >
          <div>
            <label class="block text-xs text-gray-400 mb-1">Provider</label>
            <select
              phx-change="select_provider"
              name="provider"
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-200"
            >
              <option
                :for={p <- @providers}
                value={p.name}
                selected={p.name == @new_session_provider}
              >
                {p.name} ({p.type})
              </option>
            </select>
          </div>
          <div>
            <label class="block text-xs text-gray-400 mb-1">Model</label>
            <input
              type="text"
              name="model"
              value={@new_session_model}
              phx-blur="select_model"
              phx-keydown="select_model"
              phx-key="Enter"
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-200"
              placeholder="model id"
            />
          </div>
          <button
            phx-click="create_session"
            class="w-full px-3 py-1.5 text-sm bg-green-600 text-white rounded hover:bg-green-700"
          >
            Create Session
          </button>
        </div>

        <.flash_group flash={@flash} />

        <div class="space-y-2">
          <div
            :for={session <- @sessions}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800 hover:border-gray-700"
          >
            <.link navigate={~p"/projects/#{@project.id}/sessions/#{session.id}"}>
              <div class="font-medium">
                {session.title || "Session #{String.slice(session.id, 0, 8)}"}
              </div>
              <div class="text-xs text-gray-500 mt-1">
                {session.provider}/{session.model} · {session.agent}
              </div>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
