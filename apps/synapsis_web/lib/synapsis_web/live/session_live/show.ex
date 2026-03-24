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

        # Subscribe to debug events for this session
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Synapsis.PubSub, "debug:#{session_id}")
        end

        debug_entries = load_debug_entries(session)

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
           selector_provider: selector_provider,
           new_session_debug: false,
           debug_enabled: session.debug || false,
           debug_entries: debug_entries,
           debug_panel_open: false
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

  def handle_event("toggle_new_session_debug", _params, socket) do
    {:noreply, assign(socket, new_session_debug: !socket.assigns.new_session_debug)}
  end

  def handle_event("create_session", _params, socket) do
    opts = %{
      provider: socket.assigns.new_session_provider,
      model: socket.assigns.new_session_model,
      debug: socket.assigns.new_session_debug
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

  def handle_event("open_debug_panel", _params, socket) do
    entries = load_debug_entries_from_store(socket.assigns.session.id)
    {:noreply, assign(socket, debug_panel_open: true, debug_entries: entries)}
  end

  def handle_event("close_debug_panel", _params, socket) do
    {:noreply, assign(socket, debug_panel_open: false)}
  end

  def handle_event("toggle_debug_entry", %{"id" => request_id}, socket) do
    entries =
      Enum.map(socket.assigns.debug_entries, fn entry ->
        if entry[:request_id] == request_id do
          Map.update(entry, :expanded, true, &(!&1))
        else
          entry
        end
      end)

    {:noreply, assign(socket, debug_entries: entries)}
  end

  @impl true
  def handle_info({"debug_request", payload}, socket) do
    if socket.assigns.debug_enabled do
      entry = Map.merge(payload, %{expanded: false, type: :request})
      entries = socket.assigns.debug_entries ++ [entry]
      {:noreply, assign(socket, debug_entries: entries)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({"debug_response", payload}, socket) do
    if socket.assigns.debug_enabled do
      request_id = payload["request_id"] || payload[:request_id]

      entries =
        Enum.map(socket.assigns.debug_entries, fn entry ->
          if (entry["request_id"] || entry[:request_id]) == request_id do
            Map.merge(entry, payload)
          else
            entry
          end
        end)

      {:noreply, assign(socket, debug_entries: entries)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_debug_entries(%{debug: true} = session) do
    load_debug_entries_from_store(session.id)
  end

  defp load_debug_entries(_), do: []

  defp load_debug_entries_from_store(session_id) do
    if Code.ensure_loaded?(SynapsisServer.DebugStore) and
         Process.whereis(SynapsisServer.DebugStore) != nil do
      SynapsisServer.DebugStore.list_entries(session_id)
      |> Enum.map(&Map.put(&1, :expanded, false))
    else
      []
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

  # -- Debug panel helpers --

  defp debug_method(entry),
    do: (entry[:method] || entry["method"] || "POST") |> to_string() |> String.upcase()

  defp debug_provider(entry), do: entry[:provider] || entry["provider"] || ""

  defp debug_model(entry), do: entry[:model] || entry["model"] || ""

  defp debug_status(entry) do
    s = entry[:status] || entry["status"]
    if s && s != 0, do: to_string(s), else: nil
  end

  defp debug_duration(entry) do
    entry[:duration_ms] || entry["duration_ms"]
  end

  defp debug_status_dot(entry) do
    status = entry[:status] || entry["status"]
    complete = entry[:complete] || entry["complete"]

    cond do
      is_nil(status) or status == 0 -> "bg-base-content/30"
      status == 429 -> "bg-warning"
      status >= 400 -> "bg-error"
      complete == false -> "bg-warning"
      status >= 200 and status < 300 -> "bg-success"
      true -> "bg-base-content/30"
    end
  end

  defp debug_status_class(entry) do
    status = entry[:status] || entry["status"]
    complete = entry[:complete] || entry["complete"]

    cond do
      is_nil(status) or status == 0 -> ""
      status == 429 -> "border-l-2 border-warning"
      status >= 400 -> "border-l-2 border-error"
      complete == false -> "border-l-2 border-warning"
      status >= 200 and status < 300 -> "border-l-2 border-success"
      true -> ""
    end
  end

  defp inspect_headers(headers) when is_list(headers) do
    headers
    |> Enum.map(fn
      {k, v} -> "#{k}: #{v}"
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp inspect_headers(_), do: ""

  defp format_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> body
    end
  end

  defp format_body(body) when is_map(body) do
    Jason.encode!(body, pretty: true)
  rescue
    _ -> inspect(body)
  end

  defp format_body(body), do: inspect(body)

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
            <.dm_checkbox
              name="debug"
              label="Enable Debug"
              checked={@new_session_debug}
              size="sm"
              phx-click="toggle_new_session_debug"
            />
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
                  id={"delete-session-#{s.id}"}
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
          <div :if={@debug_enabled} class="flex items-center gap-2">
            <.dm_btn
              variant="warning"
              size="xs"
              phx-click="open_debug_panel"
            >
              <.dm_mdi name="bug-outline" class="w-4 h-4" />
              <span class="hidden sm:inline ml-1">Debug</span>
            </.dm_btn>
          </div>
        </div>

        <%!-- Debug Dialog (fullscreen) --%>
        <.dm_modal
          :if={@debug_enabled}
          id="debug-dialog"
          size="xl"
          class={if @debug_panel_open, do: "modal-open", else: ""}
          hide_close
        >
          <:title class="flex items-center justify-between w-full">
            <div class="flex items-center gap-2">
              <.dm_mdi name="bug-outline" class="w-5 h-5" /> Debug Log
            </div>
            <.dm_btn variant="ghost" size="sm" phx-click="close_debug_panel">
              <.dm_mdi name="close" class="w-5 h-5" />
            </.dm_btn>
          </:title>
          <:body>
            <div class="flex flex-col w-full overflow-y-auto max-h-[80vh]">
              <div :if={@debug_entries == []} class="text-sm text-base-content/50 p-6 text-center">
                No debug entries yet. Send a message to capture API calls.
              </div>
              <div :for={entry <- @debug_entries} class="mb-2">
                <div
                  class={"flex items-center gap-2 px-3 py-2 rounded cursor-pointer hover:bg-base-300 text-sm font-mono #{debug_status_class(entry)}"}
                  phx-click="toggle_debug_entry"
                  phx-value-id={entry[:request_id] || entry["request_id"]}
                >
                  <span class={"w-2 h-2 rounded-full #{debug_status_dot(entry)}"}></span>
                  <span class="font-semibold">{debug_method(entry)}</span>
                  <span class="truncate flex-1 text-base-content/70">{debug_provider(entry)}</span>
                  <span class="text-base-content/50">{debug_model(entry)}</span>
                  <span :if={debug_status(entry)} class="font-semibold">
                    &rarr; {debug_status(entry)}
                  </span>
                  <span :if={debug_duration(entry)} class="text-base-content/50">
                    ({debug_duration(entry)}ms)
                  </span>
                </div>
                <div :if={entry[:expanded]} class="mt-1 mx-3 space-y-2">
                  <%!-- Request --%>
                  <div :if={entry[:url] || entry["url"]} class="bg-base-200 rounded p-3">
                    <div class="text-xs font-semibold text-base-content/60 mb-1">Request</div>
                    <div class="text-xs font-mono break-all text-base-content/80 mb-2">
                      {entry[:url] || entry["url"]}
                    </div>
                    <div :if={entry[:headers] || entry["headers"]} class="text-xs mb-2">
                      <details>
                        <summary class="cursor-pointer text-base-content/50">Headers</summary>
                        <pre class="mt-1 text-xs overflow-x-auto"><%= inspect_headers(entry[:headers] || entry["headers"]) %></pre>
                      </details>
                    </div>
                    <div :if={entry[:body] || entry["body"]} class="text-xs">
                      <details>
                        <summary class="cursor-pointer text-base-content/50">Body</summary>
                        <pre class="mt-1 text-xs overflow-x-auto max-h-60"><%= format_body(entry[:body] || entry["body"]) %></pre>
                      </details>
                    </div>
                  </div>
                  <%!-- Response --%>
                  <div
                    :if={
                      entry[:response_body] || entry["response_body"] || entry[:status] ||
                        entry["status"]
                    }
                    class="bg-base-200 rounded p-3"
                  >
                    <div class="text-xs font-semibold text-base-content/60 mb-1">Response</div>
                    <div
                      :if={entry[:response_headers] || entry["response_headers"]}
                      class="text-xs mb-2"
                    >
                      <details>
                        <summary class="cursor-pointer text-base-content/50">Headers</summary>
                        <pre class="mt-1 text-xs overflow-x-auto"><%= inspect_headers(entry[:response_headers] || entry["response_headers"]) %></pre>
                      </details>
                    </div>
                    <div :if={entry[:response_body] || entry["response_body"]} class="text-xs">
                      <details>
                        <summary class="cursor-pointer text-base-content/50">Body</summary>
                        <pre class="mt-1 text-xs overflow-x-auto max-h-60"><%= format_body(entry[:response_body] || entry["response_body"]) %></pre>
                      </details>
                    </div>
                    <div
                      :if={entry[:error] || entry["error"]}
                      class="mt-2 text-xs text-error"
                    >
                      Error: {inspect(entry[:error] || entry["error"])}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </:body>
        </.dm_modal>

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
