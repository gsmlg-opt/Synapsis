defmodule SynapsisWeb.AssistantLive.Setting do
  @moduledoc "Settings page for a named assistant — tabbed layout with Overview, Files, Tools, Skills, and Cron Jobs."
  use SynapsisWeb, :live_view

  alias Synapsis.Workspace
  alias Synapsis.Workspace.Identity

  @tool_categories [
    {:filesystem, "Files"},
    {:execution, "Runtime"},
    {:search, "Search"},
    {:web, "Web"},
    {:memory, "Memory"},
    {:session, "Sessions"},
    {:interaction, "UI"},
    {:orchestration, "Messaging"},
    {:planning, "Planning"},
    {:workspace, "Workspace"},
    {:swarm, "Swarm"},
    {:notebook, "Notebook"},
    {:computer, "Computer"},
    {:uncategorized, "Other"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Assistant Settings")}
  end

  @impl true
  def handle_params(%{"name" => name}, _uri, socket) do
    agent_config = Synapsis.Agent.Resolver.resolve(name)
    Identity.seed_defaults()
    identity = Identity.load_all()
    files = load_identity_files()
    tools_by_category = load_tools_by_category()
    agent_tools = MapSet.new(agent_config.tools || [])

    providers = load_providers()
    current_provider = agent_config.provider || List.first(Enum.map(providers, & &1.name))
    available_models = load_models(current_provider)

    current_model =
      agent_config.model || Synapsis.Providers.default_model(current_provider || "anthropic")

    fallbacks = agent_config[:fallback_models] || ""

    {:noreply,
     assign(socket,
       page_title: "#{String.capitalize(name)} Settings",
       assistant_name: name,
       agent_config: agent_config,
       identity: identity,
       active_tab: "overview",
       files: files,
       selected_file: nil,
       file_content: nil,
       file_dirty: false,
       tools_by_category: tools_by_category,
       agent_tools: agent_tools,
       tool_profile: "full",
       providers: providers,
       available_models: available_models,
       selected_provider: current_provider,
       selected_model: current_model,
       fallbacks: fallbacks,
       overview_dirty: false,
       show_heartbeat_form: false,
       editing_heartbeat_id: nil,
       heartbeat_form: %{},
       heartbeats: Synapsis.HeartbeatConfig.list_all()
     )}
  end

  # --- Events ---

  @impl true
  def handle_event("switch_tab", %{"tab" => "cron_jobs"}, socket) do
    {:noreply,
     assign(socket, active_tab: "cron_jobs", heartbeats: Synapsis.HeartbeatConfig.list_all())}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("select_file", %{"path" => path}, socket) do
    content =
      case Workspace.read(path) do
        {:ok, resource} -> resource.content
        {:error, _} -> nil
      end

    {:noreply, assign(socket, selected_file: path, file_content: content, file_dirty: false)}
  end

  def handle_event("update_file_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, file_content: content, file_dirty: true)}
  end

  def handle_event("save_file", _params, socket) do
    path = socket.assigns.selected_file
    content = socket.assigns.file_content

    case Workspace.write(path, content, %{author: "user", lifecycle: :shared}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(file_dirty: false, files: load_identity_files())
         |> put_flash(:info, "File saved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("reset_file", _params, socket) do
    path = socket.assigns.selected_file

    content =
      case Workspace.read(path) do
        {:ok, resource} -> resource.content
        {:error, _} -> nil
      end

    {:noreply, assign(socket, file_content: content, file_dirty: false)}
  end

  def handle_event("refresh_files", _params, socket) do
    files = load_identity_files()

    socket =
      if socket.assigns.selected_file do
        content =
          case Workspace.read(socket.assigns.selected_file) do
            {:ok, resource} -> resource.content
            {:error, _} -> nil
          end

        assign(socket, files: files, file_content: content, file_dirty: false)
      else
        assign(socket, files: files)
      end

    {:noreply, socket}
  end

  def handle_event("toggle_tool", %{"tool" => tool_name}, socket) do
    agent_tools = socket.assigns.agent_tools

    agent_tools =
      if MapSet.member?(agent_tools, tool_name) do
        MapSet.delete(agent_tools, tool_name)
      else
        MapSet.put(agent_tools, tool_name)
      end

    {:noreply, assign(socket, agent_tools: agent_tools)}
  end

  def handle_event("enable_all_tools", _params, socket) do
    all_names =
      socket.assigns.tools_by_category
      |> Enum.flat_map(fn {_cat, tools} -> Enum.map(tools, & &1.name) end)
      |> MapSet.new()

    {:noreply, assign(socket, agent_tools: all_names)}
  end

  def handle_event("disable_all_tools", _params, socket) do
    {:noreply, assign(socket, agent_tools: MapSet.new())}
  end

  def handle_event("select_provider", %{"provider" => provider_name}, socket) do
    models = load_models(provider_name)
    default = Synapsis.Providers.default_model(provider_name)

    {:noreply,
     assign(socket,
       selected_provider: provider_name,
       available_models: models,
       selected_model: default,
       overview_dirty: true
     )}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, selected_model: model, overview_dirty: true)}
  end

  def handle_event("update_fallbacks", %{"fallbacks" => fallbacks}, socket) do
    {:noreply, assign(socket, fallbacks: fallbacks, overview_dirty: true)}
  end

  def handle_event("save_config", _params, socket) do
    name = socket.assigns.assistant_name
    tools = MapSet.to_list(socket.assigns.agent_tools)

    attrs = %{
      provider: socket.assigns.selected_provider,
      model: socket.assigns.selected_model,
      fallback_models: socket.assigns.fallbacks,
      tools: tools
    }

    case Synapsis.AgentConfigs.upsert(name, attrs) do
      {:ok, _} ->
        agent_config = Synapsis.Agent.Resolver.resolve(name)

        {:noreply,
         socket
         |> assign(overview_dirty: false, agent_config: agent_config)
         |> put_flash(:info, "Agent config saved")}

      :ok ->
        {:noreply,
         socket
         |> assign(overview_dirty: false)
         |> put_flash(:info, "Agent config saved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("reload_config", _params, socket) do
    name = socket.assigns.assistant_name
    agent_config = Synapsis.Agent.Resolver.resolve(name)
    providers = load_providers()
    current_provider = agent_config.provider || List.first(Enum.map(providers, & &1.name))
    available_models = load_models(current_provider)

    {:noreply,
     assign(socket,
       agent_config: agent_config,
       providers: providers,
       available_models: available_models,
       selected_provider: current_provider,
       selected_model:
         agent_config.model || Synapsis.Providers.default_model(current_provider || "anthropic"),
       fallbacks: agent_config[:fallback_models] || "",
       overview_dirty: false
     )}
  end

  # --- Heartbeat Events ---

  def handle_event("show_new_heartbeat", _params, socket) do
    {:noreply,
     assign(socket,
       show_heartbeat_form: true,
       editing_heartbeat_id: nil,
       heartbeat_form: %{}
     )}
  end

  def handle_event("cancel_heartbeat_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_heartbeat_form: false,
       editing_heartbeat_id: nil,
       heartbeat_form: %{}
     )}
  end

  def handle_event("edit_heartbeat", %{"id" => id}, socket) do
    case Synapsis.HeartbeatConfig.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Heartbeat not found")}

      hb ->
        form = %{
          name: hb.name,
          schedule: hb.schedule,
          prompt: hb.prompt,
          agent_type: to_string(hb.agent_type),
          session_isolation: to_string(hb.session_isolation),
          notify_user: to_string(hb.notify_user),
          keep_history: to_string(hb.keep_history)
        }

        {:noreply,
         assign(socket,
           show_heartbeat_form: true,
           editing_heartbeat_id: id,
           heartbeat_form: form
         )}
    end
  end

  def handle_event("save_heartbeat", params, socket) do
    attrs = %{
      name: params["name"],
      schedule: params["schedule"],
      prompt: params["prompt"],
      agent_type: validated_atom(params["agent_type"], ~w(global project), :global),
      session_isolation:
        validated_atom(params["session_isolation"], ~w(isolated main), :isolated),
      notify_user: params["notify_user"] == "true",
      keep_history: params["keep_history"] == "true"
    }

    result =
      case params["heartbeat_id"] do
        "" ->
          Synapsis.HeartbeatConfig.create(attrs)

        id when is_binary(id) ->
          case Synapsis.HeartbeatConfig.get(id) do
            nil -> {:error, :not_found}
            hb -> Synapsis.HeartbeatConfig.update_config(hb, attrs)
          end
      end

    case result do
      {:ok, config} ->
        if config.enabled do
          Synapsis.Agent.Heartbeat.Scheduler.schedule_heartbeat(config)
        end

        {:noreply,
         socket
         |> assign(
           show_heartbeat_form: false,
           editing_heartbeat_id: nil,
           heartbeat_form: %{},
           heartbeats: Synapsis.HeartbeatConfig.list_all()
         )
         |> put_flash(:info, "Heartbeat saved")}

      {:error, %Ecto.Changeset{} = cs} ->
        msg =
          Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
          |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, "Validation error: #{msg}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_heartbeat", %{"id" => id}, socket) do
    case Synapsis.HeartbeatConfig.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Heartbeat not found")}

      hb ->
        case Synapsis.HeartbeatConfig.update_config(hb, %{enabled: not hb.enabled}) do
          {:ok, updated} ->
            if updated.enabled do
              Synapsis.Agent.Heartbeat.Scheduler.schedule_heartbeat(updated)
            end

            Synapsis.Agent.Heartbeat.Scheduler.sync_crontab()

            {:noreply,
             socket
             |> assign(heartbeats: Synapsis.HeartbeatConfig.list_all())
             |> put_flash(
               :info,
               "Heartbeat #{if updated.enabled, do: "enabled", else: "disabled"}"
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Toggle failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("delete_heartbeat", %{"id" => id}, socket) do
    case Synapsis.HeartbeatConfig.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Heartbeat not found")}

      hb ->
        case Synapsis.HeartbeatConfig.delete_config(hb) do
          {:ok, _} ->
            Synapsis.Agent.Heartbeat.Scheduler.sync_crontab()

            {:noreply,
             socket
             |> assign(heartbeats: Synapsis.HeartbeatConfig.list_all())
             |> put_flash(:info, "Heartbeat deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("reload_tools", _params, socket) do
    tools_by_category = load_tools_by_category()
    agent_config = Synapsis.Agent.Resolver.resolve(socket.assigns.assistant_name)
    agent_tools = MapSet.new(agent_config.tools || [])

    {:noreply,
     assign(socket,
       tools_by_category: tools_by_category,
       agent_tools: agent_tools,
       agent_config: agent_config
     )}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6">
      <%!-- Header --%>
      <.dm_card variant="bordered" class="mb-6">
        <div class="flex items-center gap-4">
          <div class="bg-base-300 rounded-full w-12 h-12 flex items-center justify-center text-lg font-bold text-base-content/70">
            {String.first(@assistant_name)}
          </div>
          <div class="flex-1">
            <div class="flex items-center gap-3">
              <h1 class="text-xl font-bold">{@assistant_name}</h1>
              <span class="text-xs font-mono px-2 py-0.5 rounded bg-base-300 text-base-content/60">
                {@assistant_name}
              </span>
              <span
                :if={@assistant_name == "default"}
                class="text-xs font-mono px-2 py-0.5 rounded border border-base-content/20 text-base-content/60"
              >
                DEFAULT
              </span>
            </div>
            <p class="text-sm text-base-content/50 mt-0.5">
              Agent workspace and routing.
            </p>
          </div>
        </div>
      </.dm_card>

      <%!-- Tabs --%>
      <div class="flex gap-2 mb-6">
        <.tab_button
          :for={
            {label, key} <- [
              {"Overview", "overview"},
              {"Files", "files"},
              {"Tools", "tools"},
              {"Skills", "skills"},
              {"Cron Jobs", "cron_jobs"}
            ]
          }
          label={label}
          key={key}
          active={@active_tab}
        />
      </div>

      <%!-- Tab Content --%>
      <.tab_overview
        :if={@active_tab == "overview"}
        agent_config={@agent_config}
        assistant_name={@assistant_name}
        identity={@identity}
        providers={@providers}
        available_models={@available_models}
        selected_provider={@selected_provider}
        selected_model={@selected_model}
        fallbacks={@fallbacks}
        overview_dirty={@overview_dirty}
      />
      <.tab_files
        :if={@active_tab == "files"}
        files={@files}
        selected_file={@selected_file}
        file_content={@file_content}
        file_dirty={@file_dirty}
      />
      <.tab_tools
        :if={@active_tab == "tools"}
        tools_by_category={@tools_by_category}
        agent_tools={@agent_tools}
        tool_profile={@tool_profile}
      />
      <.tab_skills :if={@active_tab == "skills"} assistant_name={@assistant_name} />
      <.tab_cron_jobs
        :if={@active_tab == "cron_jobs"}
        assistant_name={@assistant_name}
        show_heartbeat_form={@show_heartbeat_form}
        editing_heartbeat_id={@editing_heartbeat_id}
        heartbeat_form={@heartbeat_form}
        heartbeats={@heartbeats}
      />
    </div>
    """
  end

  # --- Tab Button ---

  defp tab_button(assigns) do
    ~H"""
    <.dm_btn
      variant={if @key == @active, do: "primary", else: "ghost"}
      size="sm"
      phx-click="switch_tab"
      phx-value-tab={@key}
    >
      {@label}
    </.dm_btn>
    """
  end

  # --- Overview Tab ---

  defp tab_overview(assigns) do
    primary_model =
      if assigns.selected_provider && assigns.selected_model do
        fallback_count = count_fallbacks(assigns.fallbacks)
        suffix = if fallback_count > 0, do: " (+#{fallback_count} fallback)", else: ""
        "#{assigns.selected_provider}/#{assigns.selected_model}#{suffix}"
      else
        "-"
      end

    identity_name =
      if assigns.identity.identity do
        assigns.identity.identity
        |> String.split("\n")
        |> Enum.find("", &String.contains?(&1, "Name"))
        |> then(fn
          "" -> "-"
          line -> String.trim(String.replace(line, ~r/^.*Name:?\s*/, ""))
        end)
      else
        "-"
      end

    assigns =
      assigns
      |> assign(:primary_model_display, primary_model)
      |> assign(:identity_name, identity_name)

    ~H"""
    <.dm_card variant="bordered">
      <:title>Overview</:title>
      <p class="text-xs text-base-content/50 mb-4">
        Workspace paths and identity metadata.
      </p>
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4 mb-6">
        <div>
          <div class="text-xs text-base-content/50 mb-1">Workspace</div>
          <div class="text-sm font-mono break-all">{System.user_home() || "~"}</div>
        </div>
        <div>
          <div class="text-xs text-base-content/50 mb-1">Primary Model</div>
          <div class="text-sm font-mono">{@primary_model_display}</div>
        </div>
        <div>
          <div class="text-xs text-base-content/50 mb-1">Identity Name</div>
          <div class="text-sm">{@identity_name}</div>
        </div>
        <div>
          <div class="text-xs text-base-content/50 mb-1">Default</div>
          <div class="text-sm">{if @assistant_name == "default", do: "yes", else: "no"}</div>
        </div>
        <div>
          <div class="text-xs text-base-content/50 mb-1">Identity Emoji</div>
          <div class="text-sm">-</div>
        </div>
        <div>
          <div class="text-xs text-base-content/50 mb-1">Skills Filter</div>
          <div class="text-sm">all skills</div>
        </div>
      </div>

      <div class="border-t border-base-300 pt-4">
        <div class="text-xs text-base-content/50 mb-3">Model Selection</div>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <label class="text-xs text-base-content/50 mb-1 block">Provider</label>
            <select
              phx-change="select_provider"
              name="provider"
              class="w-full bg-base-200 border border-base-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-primary/50"
            >
              <option
                :for={p <- @providers}
                value={p.name}
                selected={p.name == @selected_provider}
              >
                {p.name}
              </option>
            </select>
          </div>
          <div>
            <label class="text-xs text-base-content/50 mb-1 block">Primary model (default)</label>
            <select
              phx-change="select_model"
              name="model"
              class="w-full bg-base-200 border border-base-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-primary/50"
            >
              <option
                :for={model <- @available_models}
                value={model_id(model)}
                selected={model_id(model) == @selected_model}
              >
                {model_label(model)}
              </option>
            </select>
          </div>
          <div>
            <label class="text-xs text-base-content/50 mb-1 block">Fallbacks (comma-separated)</label>
            <input
              type="text"
              name="fallbacks"
              value={@fallbacks}
              phx-change="update_fallbacks"
              phx-debounce="300"
              placeholder="model-1, model-2, ..."
              class="w-full bg-base-200 border border-base-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-primary/50"
            />
          </div>
        </div>
      </div>

      <:action>
        <div class="flex items-center justify-end gap-2">
          <.dm_btn variant="ghost" size="sm" phx-click="reload_config">
            Reload Config
          </.dm_btn>
          <.dm_btn variant="primary" size="sm" disabled={!@overview_dirty} phx-click="save_config">
            Save
          </.dm_btn>
        </div>
      </:action>
    </.dm_card>
    """
  end

  # --- Files Tab ---

  defp tab_files(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between w-full">
          <div>
            <div>Core Files</div>
            <p class="text-xs text-base-content/50 font-normal mt-0.5">
              Bootstrap persona, identity, and tool guidance.
            </p>
          </div>
          <.dm_btn variant="ghost" size="sm" phx-click="refresh_files">
            Refresh
          </.dm_btn>
        </div>
      </:title>

      <div class="flex gap-4 min-h-[400px]">
        <%!-- File list sidebar --%>
        <div class="w-56 shrink-0 space-y-1">
          <button
            :for={file <- @files}
            phx-click="select_file"
            phx-value-path={file.path}
            class={[
              "w-full text-left px-3 py-2.5 rounded-lg border transition-colors",
              if(file.path == @selected_file,
                do: "border-primary bg-primary/10",
                else: "border-base-300 hover:border-base-content/20"
              )
            ]}
          >
            <div class="font-mono text-sm font-medium">{file.name}</div>
            <div class="text-xs text-base-content/40 mt-0.5">
              {file.status}
            </div>
          </button>
        </div>

        <%!-- File editor --%>
        <div class="flex-1 min-w-0">
          <%= if @selected_file do %>
            <div class="flex items-center justify-between mb-3">
              <div>
                <div class="font-mono text-sm font-medium">{file_name(@selected_file)}</div>
                <div class="text-xs text-base-content/40">{@selected_file}</div>
              </div>
              <div class="flex gap-2">
                <.dm_btn
                  :if={@file_dirty}
                  variant="ghost"
                  size="sm"
                  phx-click="reset_file"
                >
                  Reset
                </.dm_btn>
                <.dm_btn
                  :if={@file_dirty}
                  variant="primary"
                  size="sm"
                  phx-click="save_file"
                >
                  Save
                </.dm_btn>
              </div>
            </div>
            <div>
              <label class="text-xs text-base-content/50 mb-1 block">Content</label>
              <textarea
                phx-change="update_file_content"
                phx-debounce="300"
                name="content"
                class="w-full bg-base-200 border border-base-300 rounded-lg px-3 py-2 text-sm font-mono resize-y min-h-[320px] focus:outline-none focus:border-primary/50"
              >{@file_content || ""}</textarea>
            </div>
          <% else %>
            <div class="flex items-center justify-center h-full text-base-content/30 text-sm">
              Select a file to view and edit
            </div>
          <% end %>
        </div>
      </div>
    </.dm_card>
    """
  end

  # --- Tools Tab ---

  defp tab_tools(assigns) do
    total = count_total_tools(assigns.tools_by_category)
    enabled = MapSet.size(assigns.agent_tools)

    assigns = assign(assigns, total: total, enabled: enabled)

    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between w-full">
          <div>
            <div>Tool Access</div>
            <p class="text-xs text-base-content/50 font-normal mt-0.5">
              Profile + per-tool overrides for this agent. {@enabled}/{@total} enabled.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.dm_btn variant="ghost" size="xs" phx-click="enable_all_tools">
              Enable All
            </.dm_btn>
            <.dm_btn variant="ghost" size="xs" phx-click="disable_all_tools">
              Disable All
            </.dm_btn>
            <.dm_btn variant="ghost" size="xs" phx-click="reload_tools">
              Reload Config
            </.dm_btn>
          </div>
        </div>
      </:title>

      <%!-- Profile & Source --%>
      <div class="grid grid-cols-2 gap-4 mb-4">
        <div>
          <div class="text-xs text-base-content/50 mb-1">Profile</div>
          <div class="text-sm font-mono">{@tool_profile}</div>
        </div>
        <div>
          <div class="text-xs text-base-content/50 mb-1">Source</div>
          <div class="text-sm font-mono">default</div>
        </div>
      </div>

      <%!-- Quick Presets --%>
      <div class="mb-6">
        <div class="text-xs text-base-content/50 mb-2">Quick Presets</div>
        <div class="flex gap-2">
          <span
            :for={preset <- ~w(Minimal Coding Messaging Full Inherit)}
            class={[
              "text-xs px-3 py-1 rounded-full cursor-pointer transition-colors",
              if(String.downcase(preset) == @tool_profile,
                do: "bg-primary text-primary-content",
                else: "bg-base-300 text-base-content/60 hover:bg-base-content/10"
              )
            ]}
          >
            {preset}
          </span>
        </div>
      </div>

      <%!-- Tool Categories --%>
      <div class="space-y-6">
        <.tool_category
          :for={{category, tools} <- @tools_by_category}
          :if={tools != []}
          category={category}
          tools={tools}
          agent_tools={@agent_tools}
        />
      </div>
    </.dm_card>
    """
  end

  defp tool_category(assigns) do
    ~H"""
    <div>
      <h3 class="text-sm font-semibold text-base-content/70 mb-3">{@category}</h3>
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-x-6 gap-y-1">
        <.tool_row :for={tool <- @tools} tool={tool} agent_tools={@agent_tools} />
      </div>
    </div>
    """
  end

  defp tool_row(assigns) do
    enabled = MapSet.member?(assigns.agent_tools, assigns.tool.name)
    assigns = assign(assigns, enabled: enabled)

    ~H"""
    <div class="py-1">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2 min-w-0">
          <span class="font-mono text-sm text-base-content">{@tool.name}</span>
          <span class="text-[10px] px-1.5 py-0.5 rounded bg-base-300 text-base-content/50 shrink-0">
            core
          </span>
        </div>
        <button
          phx-click="toggle_tool"
          phx-value-tool={@tool.name}
          class="shrink-0 ml-2"
          aria-label={"Toggle #{@tool.name}"}
        >
          <div class={[
            "w-9 h-5 rounded-full relative transition-colors",
            if(@enabled, do: "bg-success", else: "bg-base-content/20")
          ]}>
            <div class={[
              "absolute top-0.5 w-4 h-4 rounded-full bg-white shadow transition-all",
              if(@enabled, do: "left-[18px]", else: "left-0.5")
            ]} />
          </div>
        </button>
      </div>
      <div class="text-[11px] text-base-content/40 truncate">{@tool.description}</div>
    </div>
    """
  end

  # --- Skills Tab ---

  defp tab_skills(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>Skills</:title>
      <.empty_state
        icon="lightning-bolt-outline"
        title="No Skills Configured"
        description={"Skills for the #{@assistant_name} agent will appear here once configured."}
      />
      <:action>
        <.dm_link
          navigate={~p"/settings/skills"}
          class="text-xs text-base-content/50 hover:text-primary"
        >
          Manage skills
        </.dm_link>
      </:action>
    </.dm_card>
    """
  end

  # --- Cron Jobs Tab ---

  defp tab_cron_jobs(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between w-full">
          <div>
            <div>Heartbeat Schedules</div>
            <p class="text-xs text-base-content/50 font-normal mt-0.5">
              Proactive agent invocations on cron schedules.
            </p>
          </div>
          <.dm_btn variant="primary" size="sm" phx-click="show_new_heartbeat">
            <.dm_mdi name="plus" class="w-4 h-4" /> New Heartbeat
          </.dm_btn>
        </div>
      </:title>

      <%!-- New heartbeat form --%>
      <div :if={@show_heartbeat_form} class="border border-primary/30 rounded-lg p-4 mb-4 bg-base-200">
        <h4 class="text-sm font-medium mb-3">
          {if @editing_heartbeat_id, do: "Edit Heartbeat", else: "New Heartbeat"}
        </h4>
        <form phx-submit="save_heartbeat" class="space-y-3">
          <input type="hidden" name="heartbeat_id" value={@editing_heartbeat_id || ""} />
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <div>
              <label class="text-xs text-base-content/50 mb-1 block">Name</label>
              <input
                type="text"
                name="name"
                value={@heartbeat_form[:name] || ""}
                placeholder="my-custom-check"
                required
                class="w-full bg-base-100 border border-base-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-primary/50"
              />
            </div>
            <div>
              <label class="text-xs text-base-content/50 mb-1 block">
                Cron Schedule
                <span class="text-base-content/30">(5-field: min hour dom mon dow)</span>
              </label>
              <input
                type="text"
                name="schedule"
                value={@heartbeat_form[:schedule] || ""}
                placeholder="0 9 * * 1-5"
                required
                class="w-full bg-base-100 border border-base-300 rounded px-3 py-2 text-sm font-mono focus:outline-none focus:border-primary/50"
              />
            </div>
          </div>
          <div>
            <label class="text-xs text-base-content/50 mb-1 block">Prompt</label>
            <textarea
              name="prompt"
              rows="3"
              required
              placeholder="Describe what this heartbeat should do..."
              class="w-full bg-base-100 border border-base-300 rounded px-3 py-2 text-sm resize-y focus:outline-none focus:border-primary/50"
            >{@heartbeat_form[:prompt] || ""}</textarea>
          </div>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
            <div>
              <label class="text-xs text-base-content/50 mb-1 block">Agent Type</label>
              <select
                name="agent_type"
                class="w-full bg-base-100 border border-base-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-primary/50"
              >
                <option
                  value="global"
                  selected={(@heartbeat_form[:agent_type] || "global") == "global"}
                >
                  Global
                </option>
                <option
                  value="project"
                  selected={(@heartbeat_form[:agent_type] || "global") == "project"}
                >
                  Project
                </option>
              </select>
            </div>
            <div>
              <label class="text-xs text-base-content/50 mb-1 block">Isolation</label>
              <select
                name="session_isolation"
                class="w-full bg-base-100 border border-base-300 rounded px-3 py-2 text-sm focus:outline-none focus:border-primary/50"
              >
                <option
                  value="isolated"
                  selected={(@heartbeat_form[:session_isolation] || "isolated") == "isolated"}
                >
                  Isolated
                </option>
                <option
                  value="main"
                  selected={(@heartbeat_form[:session_isolation] || "isolated") == "main"}
                >
                  Main
                </option>
              </select>
            </div>
            <div class="flex items-end gap-4">
              <label class="flex items-center gap-2 text-xs cursor-pointer">
                <input
                  type="checkbox"
                  name="notify_user"
                  value="true"
                  checked={@heartbeat_form[:notify_user] != "false"}
                  class="accent-primary"
                /> Notify
              </label>
              <label class="flex items-center gap-2 text-xs cursor-pointer">
                <input
                  type="checkbox"
                  name="keep_history"
                  value="true"
                  checked={@heartbeat_form[:keep_history] == "true"}
                  class="accent-primary"
                /> History
              </label>
            </div>
          </div>
          <div class="flex gap-2 pt-1">
            <.dm_btn variant="primary" size="sm" type="submit">
              {if @editing_heartbeat_id, do: "Update", else: "Create"}
            </.dm_btn>
            <.dm_btn variant="ghost" size="sm" type="button" phx-click="cancel_heartbeat_form">
              Cancel
            </.dm_btn>
          </div>
        </form>
      </div>

      <%!-- Heartbeat list --%>
      <div :if={@heartbeats != []} class="space-y-2">
        <.heartbeat_row :for={hb <- @heartbeats} heartbeat={hb} />
      </div>
      <.empty_state
        :if={@heartbeats == []}
        icon="clock-outline"
        title="No Heartbeats"
        description="Create a heartbeat to schedule proactive agent invocations."
      />
    </.dm_card>
    """
  end

  defp heartbeat_row(assigns) do
    next_run =
      case Synapsis.Agent.Heartbeat.Scheduler.next_run_time(assigns.heartbeat.schedule) do
        {:ok, dt} -> Calendar.strftime(dt, "%b %d %H:%M UTC")
        _ -> "-"
      end

    assigns = assign(assigns, :next_run, next_run)

    ~H"""
    <div class="flex items-center gap-3 p-3 rounded-lg border border-base-300 hover:border-base-content/20 transition-colors">
      <button
        phx-click="toggle_heartbeat"
        phx-value-id={@heartbeat.id}
        class="shrink-0"
        aria-label={"Toggle #{@heartbeat.name}"}
      >
        <div class={[
          "w-9 h-5 rounded-full relative transition-colors",
          if(@heartbeat.enabled, do: "bg-success", else: "bg-base-content/20")
        ]}>
          <div class={[
            "absolute top-0.5 w-4 h-4 rounded-full bg-white shadow transition-all",
            if(@heartbeat.enabled, do: "left-[18px]", else: "left-0.5")
          ]} />
        </div>
      </button>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="font-medium text-sm">{@heartbeat.name}</span>
          <span class="font-mono text-xs px-1.5 py-0.5 rounded bg-base-300 text-base-content/50">
            {@heartbeat.schedule}
          </span>
          <.dm_badge
            :if={@heartbeat.enabled}
            variant="success"
            size="sm"
          >
            active
          </.dm_badge>
        </div>
        <div class="text-xs text-base-content/40 truncate mt-0.5">{@heartbeat.prompt}</div>
        <div :if={@heartbeat.enabled} class="text-xs text-base-content/30 mt-0.5">
          Next run: {@next_run}
        </div>
      </div>
      <div class="flex items-center gap-1 shrink-0">
        <.dm_btn variant="ghost" size="xs" phx-click="edit_heartbeat" phx-value-id={@heartbeat.id}>
          <.dm_mdi name="pencil-outline" class="w-3.5 h-3.5" />
        </.dm_btn>
        <.dm_btn
          variant="ghost"
          size="xs"
          phx-click="delete_heartbeat"
          phx-value-id={@heartbeat.id}
          data-confirm="Delete this heartbeat?"
        >
          <.dm_mdi name="delete-outline" class="w-3.5 h-3.5" />
        </.dm_btn>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp load_identity_files do
    Enum.map(Identity.core_files(), fn %{name: name, path: path} ->
      status =
        case Workspace.read(path) do
          {:ok, resource} ->
            size = byte_size(resource.content || "")
            "#{format_size(size)}"

          {:error, _} ->
            "Missing"
        end

      %{name: name, path: path, status: status}
    end)
  end

  defp load_tools_by_category do
    all_tools = Synapsis.Tool.Registry.list()

    # Build a lookup: tool_name -> category
    category_lookup =
      Enum.reduce(@tool_categories, %{}, fn {cat_atom, _label}, acc ->
        tools = Synapsis.Tool.Registry.list_by_category(cat_atom)

        Enum.reduce(tools, acc, fn tool, inner ->
          Map.put(inner, tool.name, cat_atom)
        end)
      end)

    # Group all tools by category, maintaining @tool_categories order
    grouped =
      Enum.group_by(all_tools, fn tool ->
        Map.get(category_lookup, tool.name, :uncategorized)
      end)

    @tool_categories
    |> Enum.map(fn {cat_atom, label} ->
      tools =
        Map.get(grouped, cat_atom, [])
        |> Enum.sort_by(& &1.name)

      {label, tools}
    end)
    |> Enum.reject(fn {_label, tools} -> tools == [] end)
  end

  defp count_total_tools(tools_by_category) do
    Enum.reduce(tools_by_category, 0, fn {_cat, tools}, acc -> acc + length(tools) end)
  end

  defp load_providers do
    case Synapsis.Providers.list(enabled: true) do
      {:ok, list} -> list
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp load_models(nil), do: []

  defp load_models(provider_name) do
    case Synapsis.Providers.models_for(provider_name) do
      {:ok, models} -> models
      _ -> []
    end
  end

  defp model_id(model) when is_binary(model), do: model
  defp model_id(%{id: id}), do: id
  defp model_id(%{"id" => id}), do: id
  defp model_id(model), do: to_string(model)

  defp model_label(model) when is_binary(model), do: model
  defp model_label(%{name: name}), do: name
  defp model_label(%{"name" => name}), do: name
  defp model_label(%{id: id}), do: id
  defp model_label(%{"id" => id}), do: id
  defp model_label(model), do: to_string(model)

  defp count_fallbacks(nil), do: 0
  defp count_fallbacks(""), do: 0

  defp count_fallbacks(fallbacks) when is_binary(fallbacks) do
    fallbacks
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> length()
  end

  defp count_fallbacks(_), do: 0

  defp file_name(path), do: Path.basename(path)

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp validated_atom(value, allowed, default) when is_binary(value) do
    if value in allowed, do: String.to_existing_atom(value), else: default
  end

  defp validated_atom(_, _allowed, default), do: default
end
