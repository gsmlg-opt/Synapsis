defmodule SynapsisWeb.SessionLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => session_id, "project_id" => project_id}, _session, socket) do
    case {Synapsis.Projects.get(project_id), Synapsis.Sessions.get(session_id)} do
      {{:ok, project}, {:ok, session}} ->
        sessions = Synapsis.Sessions.list_by_project(project.id)
        {:ok, providers} = Synapsis.Providers.list(enabled: true)

        default_provider = if providers != [], do: hd(providers).name, else: "anthropic"
        default_type = if providers != [], do: hd(providers).type, else: "anthropic"
        available_models = fetch_provider_models(default_provider)

        default_model =
          if available_models != [],
            do: hd(available_models).id,
            else: Synapsis.Providers.default_model(default_type)

        # Models for the current session's provider (fallback to first enabled if not found)
        session_models = fetch_provider_models(session.provider)

        {selector_provider, session_models} =
          if session_models == [] and providers != [] do
            fallback = hd(providers).name
            {fallback, fetch_provider_models(fallback)}
          else
            {session.provider, session_models}
          end

        agent_mode = session.agent || "build"
        session_mode = derive_mode(session)

        {:ok,
         assign(socket,
           project: project,
           session: session,
           sessions: sessions,
           providers: providers,
           agent_mode: agent_mode,
           session_mode: session_mode,
           page_title: session.title || "Session",
           show_new_session_form: false,
           new_session_provider: default_provider,
           new_session_model: default_model,
           available_models: available_models,
           session_models: session_models,
           show_model_selector: false,
           selector_provider: selector_provider
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

  @valid_session_modes ~w(bypass_permissions ask_before_edits edit_automatically plan_mode)

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) when mode in @valid_session_modes do
    session = socket.assigns.session

    case Synapsis.Sessions.switch_mode(session.id, mode) do
      :ok ->
        agent_mode = if mode == "plan_mode", do: "plan", else: "build"

        {:noreply,
         socket
         |> assign(session_mode: mode, agent_mode: agent_mode)}

      {:error, :not_idle} ->
        {:noreply, put_flash(socket, :error, "Cannot switch mode while session is active")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to switch mode")}
    end
  end

  def handle_event("toggle_model_selector", _params, socket) do
    opening = !socket.assigns.show_model_selector

    socket =
      if opening do
        providers = socket.assigns.providers
        session_provider = socket.assigns.session.provider

        # Use session's provider if it's in enabled list, otherwise first enabled provider
        effective_provider =
          if Enum.any?(providers, &(&1.name == session_provider)) do
            session_provider
          else
            if providers != [], do: hd(providers).name, else: session_provider
          end

        session_models = fetch_provider_models(effective_provider)

        assign(socket,
          show_model_selector: true,
          selector_provider: effective_provider,
          session_models: session_models
        )
      else
        assign(socket, show_model_selector: false)
      end

    {:noreply, socket}
  end

  def handle_event("switch_provider", %{"provider" => provider_name}, socket) do
    session_models = fetch_provider_models(provider_name)
    {:noreply, assign(socket, session_models: session_models, selector_provider: provider_name)}
  end

  def handle_event("switch_model", %{"provider" => provider_name, "model" => model}, socket) do
    session = socket.assigns.session

    case Synapsis.Sessions.switch_model(session.id, provider_name, model) do
      :ok ->
        session = %{session | provider: provider_name, model: model}
        session_models = fetch_provider_models(provider_name)

        {:noreply,
         socket
         |> assign(
           session: session,
           session_models: session_models,
           show_model_selector: false
         )
         |> put_flash(:info, "Model switched to #{model}")}

      {:error, :not_idle} ->
        {:noreply, put_flash(socket, :error, "Cannot switch model while session is active")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to switch model")}
    end
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

  defp fetch_provider_models(provider_name) do
    case Synapsis.Providers.models_for(provider_name) do
      {:ok, models} -> models
      {:error, _} -> []
    end
  end

  defp provider_options(providers) do
    Enum.map(providers, fn p -> {p.name, "#{p.name} (#{p.type})"} end)
  end

  defp selector_provider_options(providers) do
    Enum.map(providers, fn p -> {p.name, p.name} end)
  end

  defp model_options(models) do
    Enum.map(models, fn m -> {m.id, m[:name] || m.id} end)
  end

  defp derive_mode(%{agent: "plan"}), do: "plan_mode"

  defp derive_mode(%{id: session_id}) do
    case Synapsis.Tool.Permission.session_config(session_id) do
      %{mode: :autonomous, allow_destructive: :allow} -> "bypass_permissions"
      %{mode: :autonomous} -> "edit_automatically"
      _ -> "ask_before_edits"
    end
  end

  defp derive_mode(_), do: "ask_before_edits"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full bg-base-100 text-base-content">
      <%!-- Sidebar --%>
      <aside class="w-64 bg-base-200 border-r border-base-300 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <.dm_link navigate={~p"/projects/#{@project.id}"} class="text-lg font-semibold">
            {@project.slug}
          </.dm_link>
          <.dm_btn variant="primary" class="mt-2 w-full" phx-click="toggle_new_session_form">
            + New Session
          </.dm_btn>
          <div :if={@show_new_session_form} class="mt-3 space-y-2">
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
            <.dm_btn variant="primary" class="w-full" phx-click="create_session">
              Create
            </.dm_btn>
          </div>
        </div>
        <div class="flex-1 overflow-y-auto">
          <.dm_left_menu active={@session.id} size="sm">
            <:title>Sessions</:title>
            <:menu
              :for={s <- @sessions}
              id={s.id}
            >
              <div class="flex justify-between items-center w-full">
                <.link
                  navigate={~p"/projects/#{@project.id}/sessions/#{s.id}"}
                  class="min-w-0 flex-1"
                >
                  <div class="text-sm truncate">
                    {s.title || "Session #{String.slice(s.id, 0, 8)}"}
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5">
                    {s.provider}/{s.model}
                  </div>
                </.link>
                <.dm_btn
                  variant="ghost"
                  size="xs"
                  confirm="Delete this session?"
                  confirm_title="Confirm Delete"
                >
                  <:confirm_action>
                    <.dm_btn
                      variant="error"
                      size="sm"
                      phx-click="delete_session"
                      phx-value-id={s.id}
                    >
                      Delete
                    </.dm_btn>
                  </:confirm_action>
                  &#10005;
                </.dm_btn>
              </div>
            </:menu>
          </.dm_left_menu>
        </div>
      </aside>

      <%!-- Main content --%>
      <main class="flex-1 min-w-0 flex flex-col">
        <%!-- Session header --%>
        <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <h2 class="font-semibold">{@session.title || "Session"}</h2>
            <.dm_dropdown position="bottom" class="z-50">
              <:trigger>
                <.dm_btn variant="ghost" size="xs">
                  {@session.provider}/{@session.model}
                  <.dm_mdi name="chevron-down" class="w-3 h-3 ml-1" />
                </.dm_btn>
              </:trigger>
              <:content class="w-80 p-3 space-y-3">
                <div>
                  <.dm_select
                    name="provider"
                    label="Provider"
                    options={selector_provider_options(@providers)}
                    value={@selector_provider}
                    size="sm"
                    phx-change="switch_provider"
                  />
                </div>
                <div class="text-xs text-base-content/60 font-semibold">Model</div>
                <div
                  :for={m <- @session_models}
                  class={"p-2 rounded cursor-pointer hover:bg-base-200 transition-colors #{if(m.id == @session.model, do: "bg-primary/10 text-primary", else: "")}"}
                  phx-click="switch_model"
                  phx-value-provider={@selector_provider}
                  phx-value-model={m.id}
                >
                  <div class="font-medium">{m[:name] || m.id}</div>
                  <div class="text-xs text-base-content/50">{m.id}</div>
                </div>
                <div :if={@session_models == []} class="text-xs text-base-content/50 p-2">
                  No models available
                </div>
              </:content>
            </.dm_dropdown>
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

        <%!-- Bottom status bar --%>
        <.session_status_bar
          current_mode={@session_mode}
          session_status={@session.status}
          on_mode_change="switch_mode"
        />
      </main>
    </div>
    """
  end
end
