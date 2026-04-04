defmodule SynapsisWeb.SessionLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    case Synapsis.Projects.get(project_id) do
      %Synapsis.Project{} = project ->
        sessions = Synapsis.Sessions.list_by_project(project.id)
        {:ok, providers} = Synapsis.Providers.list(enabled: true)
        default_provider = if providers != [], do: hd(providers).name, else: "anthropic"
        default_type = if providers != [], do: hd(providers).type, else: "anthropic"
        available_models = fetch_provider_models(default_provider)

        default_model =
          if available_models != [],
            do: hd(available_models).id,
            else: Synapsis.Providers.default_model(default_type)

        {:ok,
         assign(socket,
           project: project,
           sessions: sessions,
           providers: providers,
           page_title: "Sessions",
           show_new_session_form: false,
           new_session_provider: default_provider,
           new_session_model: default_model,
           new_session_title: "",
           available_models: available_models
         )}

      nil ->
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
    available_models = fetch_provider_models(provider_name)

    default_model =
      if available_models != [],
        do: hd(available_models).id,
        else: Synapsis.Providers.default_model(type)

    {:noreply,
     assign(socket,
       new_session_provider: provider_name,
       new_session_model: default_model,
       available_models: available_models
     )}
  end

  def handle_event("select_model", %{"value" => model}, socket) do
    {:noreply, assign(socket, new_session_model: model)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, new_session_model: model)}
  end

  def handle_event("update_title", %{"value" => title}, socket) do
    {:noreply, assign(socket, new_session_title: title)}
  end

  def handle_event("create_session", _params, socket) do
    title = String.trim(socket.assigns.new_session_title)

    opts =
      %{
        provider: socket.assigns.new_session_provider,
        model: socket.assigns.new_session_model
      }
      |> then(fn opts -> if title != "", do: Map.put(opts, :title, title), else: opts end)

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

  defp fetch_provider_models(provider_name) do
    case Synapsis.Providers.models_for(provider_name) do
      {:ok, models} -> models
      {:error, _} -> []
    end
  end

  defp provider_options(providers) do
    Enum.map(providers, fn p -> {p.name, "#{p.name} (#{p.type})"} end)
  end

  defp model_options(models) do
    Enum.map(models, fn m -> {m.id, m[:name] || m.id} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/projects"}>Projects</:crumb>
        <:crumb to={~p"/projects/#{@project.id}"}>{@project.slug}</:crumb>
        <:crumb>Sessions</:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Sessions</h1>
        <.dm_btn id="new-session-btn" variant="primary" phx-click="toggle_new_session_form">
          + New Session
        </.dm_btn>
      </div>

      <.dm_card :if={@show_new_session_form} variant="bordered" class="mb-6">
        <:title>New Session</:title>
        <div class="space-y-3">
          <.dm_input
            type="text"
            name="title"
            value={@new_session_title}
            label="Name (optional)"
            placeholder="e.g. Fix login bug"
            size="sm"
            phx-change="update_title"
          />
          <.dm_select
            name="provider"
            label="Provider"
            options={provider_options(@providers)}
            value={@new_session_provider}
            size="sm"
            phx-change="select_provider"
          />
          <%= if @available_models != [] do %>
            <.dm_select
              name="model"
              label="Model"
              options={model_options(@available_models)}
              value={@new_session_model}
              size="sm"
              phx-change="select_model"
            />
          <% else %>
            <.dm_input
              type="text"
              name="model"
              value={@new_session_model}
              label="Model"
              placeholder="model id"
              size="sm"
              phx-blur="select_model"
              phx-keydown="select_model"
              phx-key="Enter"
            />
          <% end %>
        </div>
        <:action>
          <.dm_btn variant="primary" class="w-full" phx-click="create_session">
            Create Session
          </.dm_btn>
        </:action>
      </.dm_card>

      <div :if={@sessions != []} class="space-y-2">
        <.dm_link
          :for={session <- @sessions}
          navigate={~p"/projects/#{@project.id}/sessions/#{session.id}"}
        >
          <.dm_card variant="bordered">
            <div class="font-medium">
              {session.title || "Session #{String.slice(session.id, 0, 8)}"}
            </div>
            <div class="text-xs text-base-content/50 mt-1">
              {session.provider}/{session.model} · {session.agent}
            </div>
          </.dm_card>
        </.dm_link>
      </div>

      <.empty_state
        :if={@sessions == [] && !@show_new_session_form}
        icon="chat-outline"
        title="No sessions yet"
        description="Create a new session to start chatting."
      >
        <:action>
          <.dm_btn variant="primary" phx-click="toggle_new_session_form">
            + New Session
          </.dm_btn>
        </:action>
      </.empty_state>
    </div>
    """
  end
end
