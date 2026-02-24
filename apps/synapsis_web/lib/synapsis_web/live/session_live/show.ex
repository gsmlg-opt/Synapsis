defmodule SynapsisWeb.SessionLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => session_id, "project_id" => project_id}, _session, socket) do
    case {Synapsis.Projects.get(project_id), Synapsis.Sessions.get(session_id)} do
      {{:ok, project}, {:ok, session}} ->
        sessions = Synapsis.Sessions.list_by_project(project.id)
        {:ok, providers} = Synapsis.Providers.list(enabled: true)

        {:ok,
         assign(socket,
           project: project,
           session: session,
           sessions: sessions,
           providers: providers,
           agent_mode: session.agent || "build",
           provider_label: "#{session.provider}/#{session.model}",
           page_title: session.title || "Session",
           show_new_session_form: false,
           new_session_provider: if(providers != [], do: hd(providers).name, else: "anthropic"),
           new_session_model: Synapsis.Providers.default_model("anthropic")
         )}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/projects/#{project_id}")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_agent", %{"mode" => mode}, socket) when mode in ["build", "plan"] do
    {:noreply, assign(socket, agent_mode: mode)}
  end

  def handle_event("switch_session", %{"id" => id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/projects/#{socket.assigns.project.id}/sessions/#{id}"
     )}
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    case Synapsis.Sessions.delete(id) do
      {:ok, _} ->
        sessions = Enum.reject(socket.assigns.sessions, &(&1.id == id))

        if id == socket.assigns.session.id do
          {:noreply,
           socket
           |> assign(sessions: sessions)
           |> push_navigate(to: ~p"/projects/#{socket.assigns.project.id}")}
        else
          {:noreply, assign(socket, sessions: sessions)}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete session")}
    end
  end

  def handle_event("toggle_new_session_form", _params, socket) do
    {:noreply, assign(socket, show_new_session_form: !socket.assigns.show_new_session_form)}
  end

  def handle_event("select_provider", %{"provider" => provider_name}, socket) do
    # Pick the canonical default model for the selected provider
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

  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full bg-gray-950 text-gray-100">
      <%!-- Sidebar --%>
      <aside class="w-64 bg-gray-900 border-r border-gray-800 flex flex-col">
        <div class="p-4 border-b border-gray-800">
          <.link
            navigate={~p"/projects/#{@project.id}"}
            class="text-lg font-semibold hover:text-blue-400"
          >
            {@project.slug}
          </.link>
          <button
            phx-click="toggle_new_session_form"
            class="mt-2 w-full px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            + New Session
          </button>
          <div :if={@show_new_session_form} class="mt-3 space-y-2">
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
              Create
            </button>
          </div>
        </div>
        <div class="flex-1 overflow-y-auto">
          <div
            :for={s <- @sessions}
            class={[
              "px-4 py-3 cursor-pointer border-b border-gray-800 hover:bg-gray-800 flex justify-between items-center",
              s.id == @session.id && "bg-gray-800"
            ]}
          >
            <.link
              navigate={~p"/projects/#{@project.id}/sessions/#{s.id}"}
              class="min-w-0 flex-1"
            >
              <div class="text-sm truncate">
                {s.title || "Session #{String.slice(s.id, 0, 8)}"}
              </div>
              <div class="text-xs text-gray-500 mt-0.5">
                {s.provider}/{s.model}
              </div>
            </.link>
            <button
              phx-click="delete_session"
              phx-value-id={s.id}
              class="ml-2 text-gray-600 hover:text-red-400 text-xs"
            >
              &#10005;
            </button>
          </div>
        </div>
      </aside>

      <%!-- Main content --%>
      <main class="flex-1 flex flex-col">
        <%!-- Session header --%>
        <div class="px-4 py-3 border-b border-gray-800 flex items-center justify-between">
          <div>
            <h2 class="font-semibold">{@session.title || "Session"}</h2>
            <div class="text-xs text-gray-500">{@provider_label}</div>
          </div>
          <div class="flex gap-2">
            <button
              :for={mode <- ["build", "plan"]}
              phx-click="switch_agent"
              phx-value-mode={mode}
              class={[
                "px-3 py-1 text-sm rounded",
                if(@agent_mode == mode,
                  do: "bg-blue-600 text-white",
                  else: "bg-gray-800 text-gray-400 hover:text-gray-200"
                )
              ]}
            >
              {mode}
            </button>
          </div>
        </div>

        <%!-- React ChatApp --%>
        <div
          id={"chat-#{@session.id}"}
          phx-hook="ChatApp"
          phx-update="ignore"
          data-session-id={@session.id}
          data-agent-mode={@agent_mode}
          class="flex-1 overflow-hidden"
        >
        </div>
      </main>
    </div>
    """
  end
end
