defmodule SynapsisWeb.AgentLive.Agents do
  @moduledoc "Agent module page for managing agent configurations."
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  import SynapsisWeb.AgentLive.Components

  alias Synapsis.{AgentConfig, AgentConfigs, AgentSkills, Providers, Skills, Toolsets}
  alias SynapsisWeb.AgentLive.BrowserSettings

  @config_tabs ~w(overview workspace runtime tools skills prompt management)
  @wizard_steps ~w(overview workspace runtime tools skills prompt)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_registry")
      Providers.subscribe()
    end

    {:ok,
     assign(socket,
       page_title: "Agents",
       agent: nil,
       browser_config_baseline: %{},
       selected_skill_ids: [],
       agents: [],
       skills: [],
       toolsets: [],
       providers: [],
       active_config_tab: "overview",
       wizard_mode: false,
       form_revision: 0,
       mcp_sources: [],
       mcp_catalog: [],
       mcp_loading: false,
       mcp_failures: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign_common()
      |> apply_action(socket.assigns.live_action, params)
      |> maybe_refresh_mcp()

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_config_tab", %{"tab" => tab}, socket) when tab in @config_tabs do
    {:noreply,
     assign(socket,
       active_config_tab: tab,
       wizard_mode: socket.assigns.wizard_mode && tab in @wizard_steps
     )}
  end

  def handle_event("start_wizard", _params, socket) do
    {:noreply, assign(socket, active_config_tab: "overview", wizard_mode: true)}
  end

  def handle_event("wizard_next", _params, socket) do
    {:noreply, move_wizard(socket, 1)}
  end

  def handle_event("wizard_back", _params, socket) do
    {:noreply, move_wizard(socket, -1)}
  end

  def handle_event("finish_wizard", _params, socket) do
    {:noreply, assign(socket, active_config_tab: "management", wizard_mode: false)}
  end

  def handle_event("set_agent_enabled", %{"enabled" => enabled}, socket) do
    case socket.assigns.agent do
      %AgentConfig{} = agent ->
        enabled? = enabled in ["true", true]

        case AgentConfigs.update(agent, %{enabled: enabled?}) do
          {:ok, %AgentConfig{} = updated_agent} ->
            values =
              (react_form_draft(socket.assigns, "agent-config-form") ||
                 agent_form_values(updated_agent, socket.assigns.selected_skill_ids))
              |> Map.update!("agent", &Map.put(&1, "enabled", enabled?))

            {:noreply,
             socket
             |> assign(agent: updated_agent, agents: AgentConfigs.list())
             |> reset_react_form("agent-config-form", values)
             |> put_flash(:info, if(enabled?, do: "Agent enabled", else: "Agent disabled"))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update agent")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("change_agent_form", %{"agent" => attrs} = params, socket) do
    attrs = web_fetch_form_attrs(attrs, socket)
    agent = preview_agent(socket.assigns.agent, attrs, socket.assigns.providers)
    agent = mcp_preview(agent, params)
    {:noreply, socket |> assign(agent: agent) |> assign_mcp_catalog()}
  end

  def handle_event("refresh_mcp_tools", _params, socket),
    do: {:noreply, maybe_refresh_mcp(socket)}

  def handle_event("save_agent", %{"agent" => attrs} = params, socket) do
    skill_ids = params |> Map.get("skill_ids", []) |> List.wrap()

    attrs =
      attrs
      |> web_fetch_form_attrs(socket)
      |> normalize_agent_attrs(socket.assigns.agent)
      |> Map.put("tool_contract_version", socket.assigns.agent.tool_contract_version)
      |> Map.put("tools", socket.assigns.agent.tools || [])

    policy =
      mcp_normalize_policy(
        Map.get(params, "mcp_selection", (socket.assigns.agent.config || %{})["mcp_selection"]),
        (socket.assigns.agent.config || %{})["mcp_selection"]
      )

    attrs = Map.update!(attrs, "config", &Map.put(&1, "mcp_selection", policy))

    result =
      case socket.assigns.live_action do
        :new ->
          save_browser_agent(attrs, params, socket, nil)

        :config ->
          case AgentConfigs.get(socket.assigns.agent.id) do
            nil -> {:error, :not_found}
            db_agent -> save_browser_agent(attrs, params, socket, db_agent)
          end

        _ ->
          {:error, :unsupported_action}
      end

    case result do
      {:ok, %AgentConfig{} = agent} ->
        {:ok, _skills} = AgentSkills.assign_skills(agent, skill_ids)
        Providers.notify_changed()

        {:noreply, after_agent_save(socket, agent)}

      {:error, {:browser_settings, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, save_error(reason))}
    end
  end

  def handle_event("delete_agent", %{"confirmation" => confirmation}, socket) do
    case socket.assigns.agent do
      %AgentConfig{} = agent ->
        delete_agent(socket, agent, confirmation)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:agent_mcp_catalog, {:ok, result}, socket) do
    failures =
      if is_map(result),
        do: Map.reject(result, fn {_id, status} -> status == :ok end),
        else: %{"all" => result}

    {:noreply,
     socket |> assign(mcp_loading: false, mcp_failures: failures) |> assign_mcp_catalog()}
  end

  def handle_async(:agent_mcp_catalog, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(mcp_loading: false, mcp_failures: %{"all" => reason})
     |> assign_mcp_catalog()}
  end

  @impl true
  def handle_info({:tool_registry_changed, _payload}, socket),
    do: {:noreply, assign_mcp_catalog(socket)}

  def handle_info({:mcp_source_catalog_changed, _payload}, socket),
    do: {:noreply, assign_mcp_catalog(socket)}

  def handle_info({:provider_catalog_changed}, socket) do
    socket = socket |> assign_common() |> assign_mcp_catalog()

    {:noreply,
     push_event(socket, "agent:model-options", %{
       options: provider_model_cascader_options(socket.assigns.providers)
     })}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.agent_shell active={:agents}>
      <div class="max-w-7xl mx-auto">
        <div class="flex flex-col gap-4 md:flex-row md:items-start md:justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold">Agents</h1>
            <p class="text-sm text-on-surface-variant">
              Agent workspace, runtime, tools, and identities.
            </p>
          </div>
          <.dm_link :if={@live_action == :index} navigate={~p"/agent/agents/new"}>
            <.dm_btn variant="primary" size="sm">
              <.dm_mdi name="plus" class="w-4 h-4" /> New Agent
            </.dm_btn>
          </.dm_link>
        </div>

        <.agent_form
          :if={@live_action in [:new, :config]}
          agent={@agent}
          agents={@agents}
          toolsets={@toolsets}
          skills={@skills}
          providers={@providers}
          mcp_sources={@mcp_sources}
          mcp_catalog={@mcp_catalog}
          mcp_loading={@mcp_loading}
          mcp_failures={@mcp_failures}
          selected_skill_ids={@selected_skill_ids}
          action={@live_action}
          active_tab={@active_config_tab}
          wizard_mode={@wizard_mode}
          form_revision={@form_revision}
          draft={react_form_draft(assigns, "agent-config-form")}
          delete_draft={react_form_draft(assigns, "agent-delete-form")}
        />

        <div :if={@live_action == :index} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.dm_card
            :for={agent <- @agents}
            variant="bordered"
            class="min-h-40 flex flex-col hover:border-primary/40 transition-colors"
            data-agent-card={agent.name}
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <.dm_mdi name={agent.icon || "robot-outline"} class="w-5 h-5 text-primary" />
                  <h2 class="font-semibold truncate">
                    {agent_label(agent)}
                  </h2>
                  <.dm_badge :if={agent.is_default} variant="primary" size="sm">default</.dm_badge>
                  <.dm_badge :if={!agent.enabled} variant="ghost" size="sm">disabled</.dm_badge>
                </div>
                <p class="text-xs text-on-surface-variant mt-1">{agent.description}</p>
                <div class="flex flex-wrap gap-2 text-xs text-on-surface-variant mt-3">
                  <span class="font-mono">{agent.name}</span>
                  <span>{model_summary(agent)}</span>
                  <span>{runtime_summary(agent)}</span>
                </div>
              </div>
              <div class="shrink-0 flex items-center gap-2">
                <.dm_link navigate={~p"/agent/agents/#{agent.name}/sessions"}>
                  <.dm_btn variant="secondary" size="xs">
                    <.dm_mdi name="message-text-outline" class="w-3.5 h-3.5" /> Sessions
                  </.dm_btn>
                </.dm_link>
                <.dm_link navigate={~p"/agent/agents/#{agent.id}/config"}>
                  <.dm_btn variant="ghost" size="xs">
                    <.dm_mdi name="cog-outline" class="w-3.5 h-3.5" /> Config
                  </.dm_btn>
                </.dm_link>
              </div>
            </div>
          </.dm_card>
        </div>
      </div>
    </.agent_shell>
    """
  end

  attr :agent, :map, required: true
  attr :agents, :list, required: true
  attr :action, :atom, required: true
  attr :toolsets, :list, required: true
  attr :skills, :list, required: true
  attr :providers, :list, required: true
  attr :mcp_sources, :list, required: true
  attr :mcp_catalog, :list, required: true
  attr :mcp_loading, :boolean, required: true
  attr :mcp_failures, :map, required: true
  attr :selected_skill_ids, :list, required: true
  attr :active_tab, :string, required: true
  attr :wizard_mode, :boolean, required: true
  attr :form_revision, :integer, required: true
  attr :draft, :map, default: nil
  attr :delete_draft, :map, default: nil

  defp agent_form(assigns) do
    selected_toolsets = selected_toolsets(assigns.agent, assigns.toolsets)
    selected_toolset_ids = selected_toolset_ids(assigns.agent)
    missing_toolset_ids = selected_toolset_ids -- Enum.map(assigns.toolsets, & &1.id)
    tool_names = agent_tool_names(assigns.agent, selected_toolsets)
    fallback_tokens = fallback_tokens(assigns.agent.fallback_models)
    workspace_path = workspace_path(assigns.agent)
    permission_mode = permission_mode(assigns.agent)

    mcp_policy =
      mcp_normalize_policy(
        (assigns.draft || %{})["mcp_selection"] || (assigns.agent.config || %{})["mcp_selection"],
        (assigns.agent.config || %{})["mcp_selection"]
      )

    mcp_groups = mcp_groups(assigns.mcp_sources, assigns.mcp_catalog, mcp_policy)

    deferred_tools =
      deferred_tool_choices(assigns.agent, assigns.toolsets, mcp_groups, mcp_policy)

    draft =
      if assigns.draft do
        Map.put(assigns.draft, "mcp_selection", mcp_form_policy(mcp_policy))
      end

    form_structure = [
      mcp_policy,
      Enum.map(mcp_groups, &{&1.id, &1.name, &1.enabled, &1.status, &1.tools}),
      deferred_tools,
      assigns.active_tab,
      assigns.wizard_mode,
      Enum.map(assigns.toolsets, & &1.id),
      Enum.map(assigns.skills, & &1.id),
      assigns.form_revision
    ]

    assigns =
      assigns
      |> assign(:draft, draft)
      |> assign(:mcp_policy, mcp_policy)
      |> assign(:mcp_groups, mcp_groups)
      |> assign(:deferred_tools, deferred_tools)
      |> assign(:deferred_tool_names, deferred_tool_names(assigns.agent))
      |> assign(:form_structure, form_structure)
      |> assign(:selected_toolsets, selected_toolsets)
      |> assign(:selected_toolset_ids, selected_toolset_ids)
      |> assign(:missing_toolset_ids, missing_toolset_ids)
      |> assign(:tool_names, tool_names)
      |> assign(:native_tool_selection, native_tool_selection?(assigns.agent, assigns.toolsets))
      |> assign(:permission_mode, permission_mode)
      |> assign(:fallback_count, length(fallback_tokens))
      |> assign(:fallback_tokens, fallback_tokens)
      |> assign(:skill_count, length(assigns.selected_skill_ids))
      |> assign(:workspace_path, workspace_path)
      |> assign(:delete_confirmation, delete_confirmation(assigns.agent))
      |> assign(:tabs, config_tabs(assigns.action))
      |> assign(:wizard_steps, @wizard_steps)
      |> assign(:wizard_step_index, wizard_step_index(assigns.active_tab))
      |> assign(:wizard_step_count, length(@wizard_steps))
      |> assign(:wizard_step_label, wizard_step_label(assigns.active_tab))

    ~H"""
    <div class="space-y-5">
      <p :if={!@native_tool_selection} class="text-sm text-warning">
        Legacy selection or unavailable linked Toolset. Explicit migration required for legacy
        selections before native runtime use. Ordinary edits preserve saved tools, links and versions.
      </p>
      <p :if={@native_tool_selection} class="text-sm text-on-surface-variant">
        Native contract v1. Tool metadata and saved selections do not establish runtime readiness
        or grant permission. Runtime checks still apply.
      </p>
      <section class="rounded-lg border border-outline-variant bg-surface-container p-5">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <.dm_mdi name={@agent.icon || "robot-outline"} class="w-6 h-6 text-primary" />
              <h2 class="text-xl font-bold truncate">
                {if @action == :new, do: "New Agent", else: agent_label(@agent)}
              </h2>
              <span class="text-xs font-mono px-2 py-0.5 rounded bg-surface-container-high text-on-surface-variant">
                {@agent.name || "unsaved"}
              </span>
              <.dm_badge :if={@agent.is_default} variant="primary" size="sm">default</.dm_badge>
              <.dm_badge :if={!@agent.enabled} variant="ghost" size="sm">disabled</.dm_badge>
            </div>
            <p class="text-sm text-on-surface-variant mt-1">
              Agent workspace for memory files, notes, tools, skills, and runtime policy.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <.dm_link navigate={~p"/agent/agents"}>
              <.dm_btn type="button" variant="ghost" size="sm">Cancel</.dm_btn>
            </.dm_link>
            <button
              :if={@active_tab != "management"}
              type="submit"
              form={form_mount_id("agent-config-form", @form_structure) <> "-native"}
              class="inline-flex h-8 items-center justify-center gap-1.5 rounded-md bg-primary px-3 text-sm font-medium text-primary-content transition-colors hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-primary/30"
            >
              <.dm_mdi name="content-save-outline" class="w-3.5 h-3.5" /> Save Agent
            </button>
          </div>
        </div>

        <div :if={@action == :config} class="mt-5 max-w-sm">
          <.dm_select
            name="agent_picker"
            label="Selected agent"
            value={@agent.id}
            options={Enum.map(@agents, &{&1.id, agent_option_label(&1)})}
            disabled
          />
        </div>
      </section>

      <section
        :if={@wizard_mode and @active_tab in @wizard_steps}
        class="rounded-lg border border-primary bg-primary-container text-on-primary-container p-4"
      >
        <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div>
            <div class="text-sm font-semibold">
              Wizard step {@wizard_step_index} of {@wizard_step_count}
            </div>
            <div class="text-xs opacity-80">{@wizard_step_label}</div>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.dm_btn
              type="button"
              variant="ghost"
              size="sm"
              phx-click="wizard_back"
              disabled={@wizard_step_index == 1}
            >
              Back
            </.dm_btn>
            <.dm_btn
              :if={@wizard_step_index < @wizard_step_count}
              type="button"
              variant="primary"
              size="sm"
              phx-click="wizard_next"
            >
              Next Step
            </.dm_btn>
            <.dm_btn
              :if={@wizard_step_index == @wizard_step_count}
              type="button"
              variant="primary"
              size="sm"
              phx-click="finish_wizard"
            >
              Finish Wizard
            </.dm_btn>
          </div>
        </div>
      </section>

      <div class="grid grid-cols-1 lg:grid-cols-[13rem_minmax(0,1fr)] gap-5 items-start">
        <nav class="rounded-lg border border-outline-variant bg-surface-container p-2">
          <button
            :for={{label, key, icon} <- @tabs}
            type="button"
            phx-click="switch_config_tab"
            phx-value-tab={key}
            class={[
              "w-full flex items-center gap-2 rounded-md px-3 py-2 text-left text-sm font-medium transition-colors",
              if(@active_tab == key,
                do: "bg-primary text-primary-content",
                else: "text-on-surface-variant hover:bg-surface-container-high"
              )
            ]}
          >
            <.dm_mdi name={icon} class="w-4 h-4 shrink-0" />
            <span>{label}</span>
          </button>
        </nav>

        <div class="min-w-0">
          <.react_form
            for={%{}}
            as={:agent}
            id="agent-config-form"
            values={agent_form_values(@agent, @selected_skill_ids)}
            draft={@draft}
            structure={@form_structure}
            phx-submit="save_agent"
            phx-change="change_agent_form"
            class={if @active_tab == "management", do: "hidden", else: "space-y-5"}
          >
            <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 - retain native fields with required, placeholder, min, rows and resize attributes. --%>
            <section class={tab_panel_class(@active_tab, "overview")}>
              <div class="mb-5">
                <h3 class="text-lg font-semibold">Overview</h3>
                <p class="text-sm text-on-surface-variant">
                  Identity, model routing, and assignment metadata.
                </p>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4 mb-6">
                <.overview_metric label="Agent ID" value={@agent.id || "pending"} mono />
                <.overview_metric label="Default model" value={model_summary(@agent)} mono />
                <.overview_metric label="Runtime" value={runtime_summary(@agent)} />
                <.overview_metric label="Skills Filter" value={skills_summary(@skill_count)} />
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4 border-t border-outline-variant pt-5">
                <.dm_input
                  :if={@action == :new}
                  type="text"
                  name="agent[name]"
                  value={@agent.name}
                  required
                  label="Name"
                  placeholder="researcher"
                />
                <.readonly_field :if={@action == :config} label="Name" value={@agent.name} />
                <.dm_react_field type="text" name="agent[label]" label="Label" />
                <.dm_react_field type="text" name="agent[icon]" label="Icon" />
                <div class="form-group">
                  <label for="agent-provider-model-picker-provider" class="form-label">
                    <span>Default model</span>
                  </label>
                  <div
                    id="agent-provider-model-picker"
                    phx-hook="AgentModelPicker"
                    phx-update="ignore"
                    data-agent-id={@agent.id || "new"}
                    data-options={Jason.encode!(provider_model_cascader_options(@providers))}
                    data-provider={@agent.provider || ""}
                    data-model={@agent.model || ""}
                    data-provider-input="agent-provider-hidden"
                    data-model-input="agent-model-hidden"
                    data-state-input="agent-provider-model-state"
                  >
                    <input
                      id="agent-provider-hidden"
                      type="hidden"
                      name="agent[provider]"
                      value={@agent.provider || ""}
                    />
                    <input
                      id="agent-model-hidden"
                      type="hidden"
                      name="agent[model]"
                      value={@agent.model || ""}
                    />
                    <input
                      id="agent-provider-model-state"
                      type="hidden"
                      name="agent[provider_model_state]"
                      value={provider_model_state_value(@agent)}
                    />
                  </div>
                </div>
                <div class="form-group">
                  <label for="agent-backup-model-picker-provider" class="form-label">
                    <span>Backup model</span>
                  </label>
                  <div
                    id="agent-backup-model-picker"
                    phx-hook="AgentBackupModelPicker"
                    phx-update="ignore"
                    data-agent-id={@agent.id || "new"}
                    data-options={Jason.encode!(provider_model_cascader_options(@providers))}
                    data-backup-model={@agent.fallback_models || ""}
                    data-value-input="agent-fallback-models-hidden"
                    data-state-input="agent-fallback-model-state"
                  >
                    <input
                      id="agent-fallback-models-hidden"
                      type="hidden"
                      name="agent[fallback_models]"
                      value={@agent.fallback_models || ""}
                    />
                    <input
                      id="agent-fallback-model-state"
                      type="hidden"
                      name="agent[fallback_model_state]"
                      value={fallback_model_state_value(@agent)}
                    />
                  </div>
                </div>
                <.dm_textarea
                  name="agent[description]"
                  value={@agent.description}
                  rows={2}
                  label="Description"
                  resize="none"
                />
              </div>

              <div :if={@fallback_tokens != []} class="mt-5">
                <div class="text-xs text-on-surface-variant mb-3">Backup model</div>
                <div class="flex flex-wrap gap-2 mt-3">
                  <span
                    :for={model <- @fallback_tokens}
                    class="text-xs font-mono px-2 py-1 rounded-full bg-surface-container-high text-on-surface-variant"
                  >
                    {model}
                  </span>
                </div>
              </div>
            </section>

            <section class={tab_panel_class(@active_tab, "workspace")}>
              <div class="mb-5">
                <h3 class="text-lg font-semibold">Workspace</h3>
                <p class="text-sm text-on-surface-variant">
                  Agent-owned directory for memory files, notes, scratch files, and working artifacts.
                </p>
              </div>

              <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_18rem] gap-5">
                <div>
                  <.dm_input
                    type="text"
                    name="agent[workspace_path]"
                    value={@workspace_path}
                    label="Workspace directory"
                    placeholder="~/.synapsis/agents/main"
                  />
                  <p class="text-xs text-on-surface-variant mt-2">
                    The agent owns this directory. Store long-lived memory, notes, and local work files here.
                  </p>
                </div>

                <div class="rounded-lg border border-outline-variant bg-surface-container-high p-4 text-sm">
                  <div class="text-xs text-on-surface-variant mb-3">Suggested Layout</div>
                  <div class="space-y-2 font-mono text-xs">
                    <div>{@workspace_path}/memory</div>
                    <div>{@workspace_path}/notes</div>
                    <div>{@workspace_path}/work</div>
                  </div>
                </div>
              </div>
            </section>

            <section class={tab_panel_class(@active_tab, "runtime")}>
              <div class="mb-5">
                <h3 class="text-lg font-semibold">Runtime</h3>
                <p class="text-sm text-on-surface-variant">
                  Execution policy and model budget for this agent.
                </p>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <.dm_select
                  name="agent[reasoning_effort]"
                  label="Reasoning effort"
                  options={
                    Enum.map(AgentConfig.valid_reasoning_efforts(), &{&1, String.capitalize(&1)})
                  }
                  value={@agent.reasoning_effort || "medium"}
                />
                <.dm_select
                  name="agent[model_tier]"
                  label="Model tier"
                  options={Enum.map(AgentConfig.valid_model_tiers(), &{&1, String.capitalize(&1)})}
                  value={@agent.model_tier || "default"}
                />
                <.dm_input
                  type="number"
                  name="agent[max_tokens]"
                  value={@agent.max_tokens || 8192}
                  label="Max tokens"
                  min="1"
                />
              </div>

              <div class="flex flex-wrap gap-6 mt-5">
                <.dm_checkbox
                  name="agent[enabled]"
                  value="true"
                  checked={@agent.enabled}
                  label="Enabled"
                />

                <.dm_checkbox
                  name="agent[read_only]"
                  value="true"
                  checked={@agent.read_only}
                  label="Read-only runtime"
                />
              </div>
            </section>

            <section class={tab_panel_class(@active_tab, "tools")}>
              <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between mb-5">
                <div>
                  <h3 class="text-lg font-semibold">Tools {length(@tool_names)}</h3>
                  <p class="text-sm text-on-surface-variant">
                    Assign a named toolset made from built-in tools and MCP tools.
                  </p>
                </div>
                <.dm_link navigate={~p"/agent/tools"}>
                  <.dm_btn type="button" variant="ghost" size="sm">Manage Toolsets</.dm_btn>
                </.dm_link>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.dm_select
                  name="agent[permission_mode]"
                  label="Permission mode"
                  options={permission_mode_options()}
                  value={@permission_mode}
                />
              </div>

              <.dm_textarea
                id="agent-web-allowed-hosts"
                name="agent[web_allowed_hosts]"
                value={web_allowed_hosts_value(@agent)}
                label="Web fetch allowed hosts"
                helper="Required for web::fetch. Enter one hostname per line, without a URL scheme or path. Leave blank to make web::fetch unavailable. Tool selection is managed separately."
                placeholder="docs.example.com"
                rows={3}
                class="mt-5"
              />

              <BrowserSettings.editor
                config={@agent.config || %{}}
                draft={(@draft || %{})["browser_settings"]}
              />

              <div class="mt-5">
                <div class="mb-2 flex items-center justify-between gap-3">
                  <div>
                    <div class="text-sm font-medium">Toolsets</div>
                    <div class="text-xs text-on-surface-variant">
                      Add or remove named toolsets for this agent.
                    </div>
                  </div>
                  <.dm_link navigate={~p"/agent/tools/new"}>
                    <.dm_btn type="button" variant="ghost" size="xs">New Toolset</.dm_btn>
                  </.dm_link>
                </div>

                <input type="hidden" name="agent[toolset_ids][]" value="" />

                <div
                  :if={@toolsets != [] or @missing_toolset_ids != []}
                  class="grid grid-cols-1 md:grid-cols-2 gap-2"
                  data-testid="agent-toolset-list"
                >
                  <label
                    :for={toolset <- @toolsets}
                    data-toolset-id={toolset.id}
                    class="flex items-start gap-2 rounded border border-outline-variant bg-surface-container-high p-3 text-sm"
                  >
                    <input
                      type="checkbox"
                      name="agent[toolset_ids][]"
                      value={toolset.id}
                      checked={toolset.id in @selected_toolset_ids}
                    />
                    <span class="min-w-0">
                      <span class="font-medium">{toolset.name}</span>
                      <span class="block text-xs text-on-surface-variant">
                        {if toolset.tool_contract_version == 1,
                          do: "Native contract v1",
                          else: "Legacy contract v0"}
                        <span
                          :if={toolset.tool_contract_version != 1}
                          class="text-warning"
                        >
                          · incompatible version; migration required
                        </span>
                      </span>
                      <span class="block text-xs text-on-surface-variant">
                        {toolset.description || "#{length(toolset.tool_names || [])} tools"}
                      </span>
                      <span class="mt-2 flex flex-wrap gap-1">
                        <span
                          :for={tool_name <- Enum.take(toolset.tool_names || [], 4)}
                          class="rounded bg-surface px-1.5 py-0.5 font-mono text-[11px] text-on-surface-variant"
                        >
                          {tool_name}
                        </span>
                        <span
                          :if={length(toolset.tool_names || []) > 4}
                          class="text-[11px] text-on-surface-variant"
                        >
                          +{length(toolset.tool_names || []) - 4}
                        </span>
                      </span>
                    </span>
                  </label>
                  <label
                    :for={id <- @missing_toolset_ids}
                    data-unavailable-toolset={id}
                    class="flex items-start gap-2 rounded border border-outline-variant bg-surface-container-high p-3 text-sm"
                  >
                    <input
                      type="checkbox"
                      name="agent[toolset_ids][]"
                      value={id}
                      checked
                    />
                    <span class="min-w-0">
                      <span class="font-medium">Toolset unavailable</span>
                      <span class="block break-all font-mono text-xs text-on-surface-variant">{id}</span>
                    </span>
                  </label>
                </div>

                <div :if={@toolsets == []} class="text-sm text-on-surface-variant">
                  No toolsets are available. Create one from Agents > Tools.
                </div>
              </div>

              <div class="mt-6 space-y-4" data-testid="agent-mcp-selection">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <h4 class="font-medium">MCP tools</h4>
                    <p class="text-xs text-on-surface-variant">
                      All includes tools discovered in future turns. Group rules override the default.
                    </p>
                  </div>
                  <.dm_btn
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="refresh_mcp_tools"
                    disabled={@mcp_loading}
                  >
                    Refresh tools
                  </.dm_btn>
                </div>
                <p :if={@mcp_loading} role="status" class="text-sm text-on-surface-variant">
                  Refreshing live MCP tools…
                </p>
                <p :if={map_size(@mcp_failures) > 0} role="alert" class="text-sm text-error">
                  Live discovery failed for one or more sources. Their tools are unavailable until refresh succeeds; saved selections are retained.
                </p>
                <.dm_select
                  name="mcp_selection[default]"
                  label="Default MCP selection"
                  value={@mcp_policy["default"]}
                  options={[{"all", "All MCP tools"}, {"selected", "Only selected groups and tools"}]}
                />
                <div
                  :for={group <- @mcp_groups}
                  data-mcp-source={group.id}
                  class="rounded-lg border border-outline-variant p-3 space-y-3"
                >
                  <div class="flex items-center justify-between gap-2">
                    <span class="font-medium"><span :if={group.unavailable}>MCP source unavailable · </span>{group.name}</span>
                    <span class="text-xs text-on-surface-variant">
                      {length(group.tools)} tools{if group.status, do: " · #{group.status}", else: ""}
                    </span>
                  </div>
                  <.dm_select
                    name={"mcp_selection[sources][#{group.id}][mode]"}
                    label={"Selection for #{group.name}"}
                    value={group.mode}
                    options={[
                      {"inherit", "Use default"},
                      {"all", "All in this group"},
                      {"selected", "Select tools"},
                      {"none", "None in this group"}
                    ]}
                  />
                  <div :if={group.mode == "selected"} class="space-y-2">
                    <input
                      type="hidden"
                      name={"mcp_selection[sources][#{group.id}][tools][]"}
                      value=""
                    />
                    <label :for={tool <- group.tools} class="flex items-start gap-2 text-sm">
                      <input
                        type="checkbox"
                        name={"mcp_selection[sources][#{group.id}][tools][]"}
                        value={tool.name}
                        checked={tool.name in group.selected}
                      />
                      <span class="font-mono">{tool.name}<span
                        :if={!tool.available}
                        class="ml-2 text-xs text-on-surface-variant"
                      >unavailable</span></span>
                    </label>
                    <p :if={group.tools == []} class="text-xs text-on-surface-variant">
                      No tools discovered.
                    </p>
                  </div>
                  <input
                    :for={name <- if(group.mode != "selected", do: group.selected, else: [])}
                    type="hidden"
                    name={"mcp_selection[sources][#{group.id}][tools][]"}
                    value={name}
                  />
                </div>
              </div>

              <div id="agent-deferred-tools" class="mt-6 space-y-3">
                <div>
                  <h4 class="font-medium">Deferred tools</h4>
                  <p class="text-xs text-on-surface-variant">
                    Selected tools listed here become available after tool search. Leave empty to show all selected tools immediately.
                  </p>
                </div>
                <input type="hidden" name="agent[deferred_tool_names][]" value="" />
                <label
                  :for={tool <- @deferred_tools}
                  data-unavailable-deferred-tool={if(!tool.available, do: tool.name)}
                  class="flex items-start gap-2 text-sm"
                >
                  <input
                    type="checkbox"
                    name="agent[deferred_tool_names][]"
                    value={tool.name}
                    checked={tool.name in @deferred_tool_names}
                  />
                  <span class="break-all font-mono">
                    {tool.name}<span
                      :if={!tool.available}
                      class="ml-2 text-xs text-on-surface-variant"
                    >unavailable or no longer selected</span>
                  </span>
                </label>
                <p
                  :if={Enum.any?(@deferred_tools, &(!&1.available))}
                  class="text-xs text-warning"
                >
                  Saved unavailable entries are retained. Remove them to use the current selected catalog.
                </p>
                <p :if={@deferred_tools == []} class="text-xs text-on-surface-variant">
                  Select tools above to make them available for deferral.
                </p>
              </div>

              <div class="mt-5">
                <div class="text-xs text-on-surface-variant mb-2">Enabled Tools</div>
                <div class="flex flex-wrap gap-2">
                  <span
                    :for={tool_name <- @tool_names}
                    class="text-xs font-mono px-2 py-1 rounded-full bg-surface-container-high text-on-surface-variant"
                  >
                    {tool_name}
                  </span>
                  <span :if={@tool_names == []} class="text-sm text-on-surface-variant">
                    No tools assigned.
                  </span>
                </div>
              </div>
            </section>

            <section class={tab_panel_class(@active_tab, "skills")}>
              <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between mb-5">
                <div>
                  <h3 class="text-lg font-semibold">Skills {@skill_count}</h3>
                  <p class="text-sm text-on-surface-variant">
                    Attach prompt fragments and skill-specific tool constraints to this agent.
                  </p>
                </div>
                <.dm_link navigate={~p"/agent/skills"}>
                  <.dm_btn type="button" variant="ghost" size="sm">Manage Skills</.dm_btn>
                </.dm_link>
              </div>

              <input type="hidden" name="skill_ids[]" value="" />
              <div
                :for={group <- skill_source_groups(@skills)}
                data-skill-source={group.id}
                class="mb-4"
              >
                <h4 class="font-medium mb-2">{group.label}</h4>
                <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                  <label
                    :for={skill <- group.skills}
                    class="flex items-start gap-3 rounded-lg border border-outline-variant bg-surface-container-high p-3 text-sm"
                  >
                    <input
                      type="checkbox"
                      name="skill_ids[]"
                      value={skill.id}
                      checked={skill.id in @selected_skill_ids}
                      class="mt-1"
                    />
                    <span class="min-w-0">
                      <span class="font-medium">{skill.name}</span>
                      <span class="block text-xs text-on-surface-variant mt-1">
                        {skill.description || skill.system_prompt_fragment || "No description"}
                      </span>
                    </span>
                  </label>
                </div>
              </div>
              <p :if={@skills == []} class="text-sm text-on-surface-variant">
                No skills have been configured yet.
              </p>
            </section>

            <section class={tab_panel_class(@active_tab, "prompt")}>
              <div class="mb-5">
                <h3 class="text-lg font-semibold">System Prompt</h3>
                <p class="text-sm text-on-surface-variant">
                  Base identity and behavior instructions for every conversation using this agent.
                </p>
              </div>

              <.dm_textarea
                name="agent[system_prompt]"
                value={@agent.system_prompt}
                rows={10}
                label="System Prompt"
                resize="vertical"
              />
            </section>

            <div class={
              if @active_tab == "management",
                do: "hidden",
                else: "flex items-center justify-end gap-2"
            }>
              <.dm_link navigate={~p"/agent/agents"}>
                <.dm_btn type="button" variant="ghost">Cancel</.dm_btn>
              </.dm_link>
              <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            </div>
          </.react_form>

          <section class={tab_panel_class(@active_tab, "management")}>
            <div class="mb-5">
              <h3 class="text-lg font-semibold">Management</h3>
              <p class="text-sm text-on-surface-variant">
                Guided setup, availability, and destructive controls for this agent.
              </p>
            </div>

            <div :if={@action == :new} class="text-sm text-on-surface-variant">
              Save the agent before management controls are available.
            </div>

            <div :if={@action == :config} class="space-y-5">
              <div class="rounded-lg border border-outline-variant bg-surface-container-high p-4">
                <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
                  <div>
                    <h4 class="font-semibold">Configuration Wizard</h4>
                    <p class="text-sm text-on-surface-variant mt-1">
                      Walk through identity, workspace, runtime, tools, skills, and prompt setup.
                    </p>
                  </div>
                  <.dm_btn type="button" variant="primary" size="sm" phx-click="start_wizard">
                    Start Wizard
                  </.dm_btn>
                </div>
              </div>

              <div class="rounded-lg border border-outline-variant bg-surface-container-high p-4">
                <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
                  <div>
                    <h4 class="font-semibold">Availability</h4>
                    <p class="text-sm text-on-surface-variant mt-1">
                      Disabled agents stay configured but cannot be selected for new chat sessions.
                    </p>
                  </div>
                  <.dm_btn
                    :if={@agent.enabled}
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="set_agent_enabled"
                    phx-value-enabled="false"
                  >
                    Disable Agent
                  </.dm_btn>
                  <.dm_btn
                    :if={!@agent.enabled}
                    type="button"
                    variant="primary"
                    size="sm"
                    phx-click="set_agent_enabled"
                    phx-value-enabled="true"
                  >
                    Enable Agent
                  </.dm_btn>
                </div>
              </div>

              <.react_form
                :if={deletable_agent?(@agent)}
                for={%{}}
                id="agent-delete-form"
                draft={@delete_draft}
                phx-submit="delete_agent"
                class="space-y-4"
              >
                <div class="rounded-lg border border-error bg-error-container text-on-error-container p-4">
                  <div class="font-medium">Delete Agent</div>
                  <p class="text-sm mt-1">
                    Permanently remove this agent configuration and its skill assignments. Type
                    <span class="font-mono">{@delete_confirmation}</span>
                    to confirm.
                  </p>
                </div>

                <.dm_input
                  type="text"
                  name="confirmation"
                  value=""
                  label="Confirmation"
                  placeholder={@delete_confirmation}
                />

                <div class="flex justify-end">
                  <.dm_btn type="submit" variant="error">
                    Delete Agent
                  </.dm_btn>
                </div>
              </.react_form>

              <div
                :if={!deletable_agent?(@agent)}
                class="rounded-lg border border-outline-variant bg-surface-container-high p-4 text-sm text-on-surface-variant"
              >
                Default agent cannot be deleted.
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp overview_metric(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-on-surface-variant mb-1">{@label}</div>
      <div class={["text-sm break-words", if(@mono, do: "font-mono", else: "font-medium")]}>
        {@value}
      </div>
    </div>
    """
  end

  defp assign_common(socket) do
    assign(socket,
      agents: AgentConfigs.list(),
      toolsets: Toolsets.list(),
      skills: Skills.list(),
      providers: load_providers(),
      mcp_sources: Synapsis.MCPConfigs.list()
    )
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Agents", agent: nil, selected_skill_ids: [], wizard_mode: false)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Agent",
      browser_config_baseline: %{},
      agent: %AgentConfig{
        tool_contract_version: 1,
        tools: [],
        enabled: true,
        icon: "robot-outline",
        config: %{"mcp_selection" => %{"default" => "all", "sources" => %{}}}
      },
      selected_skill_ids: [],
      active_config_tab: "overview",
      wizard_mode: false
    )
  end

  defp apply_action(socket, :config, %{"id" => id}) do
    case get_agent_config(id) do
      %AgentConfig{} = agent ->
        agent = mcp_initialize_policy(agent, socket.assigns.mcp_sources)

        assign(socket,
          page_title: "Agent Config",
          browser_config_baseline: agent.config || %{},
          agent: agent,
          selected_skill_ids: AgentSkills.list_skill_ids(agent.id),
          active_config_tab: "overview",
          wizard_mode: false
        )

      nil ->
        socket
        |> put_flash(:error, "Agent not found")
        |> push_navigate(to: ~p"/agent/agents")
    end
  end

  defp get_agent_config(id_or_name) do
    case Ecto.UUID.cast(id_or_name) do
      {:ok, id} -> AgentConfigs.get(id)
      :error -> AgentConfigs.get_by_name(id_or_name)
    end
  end

  defp agent_form_values(agent, skill_ids) do
    values =
      agent
      |> Map.from_struct()
      |> Map.take([
        :name,
        :label,
        :icon,
        :description,
        :provider,
        :model,
        :fallback_models,
        :reasoning_effort,
        :model_tier,
        :max_tokens,
        :enabled,
        :read_only,
        :system_prompt
      ])
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("reasoning_effort", agent.reasoning_effort || "medium")
      |> Map.put("model_tier", agent.model_tier || "default")
      |> Map.put("max_tokens", agent.max_tokens || 8192)
      |> Map.put("workspace_path", workspace_path(agent))
      |> Map.put("web_allowed_hosts", web_allowed_hosts_value(agent))
      |> Map.put("permission_mode", permission_mode(agent))
      |> Map.put("toolset_ids", selected_toolset_ids(agent))
      |> Map.put("deferred_tool_names", deferred_tool_names(agent))
      |> Map.put("provider_model_state", provider_model_state_value(agent))
      |> Map.put("fallback_model_state", fallback_model_state_value(agent))

    %{
      "agent" => values,
      "skill_ids" => skill_ids,
      "browser_settings" => BrowserSettings.form_values(agent.config || %{}),
      "mcp_selection" => mcp_form_policy((agent.config || %{})["mcp_selection"])
    }
  end

  defp after_agent_save(%{assigns: %{live_action: :new}} = socket, _agent) do
    socket
    |> put_flash(:info, "Agent saved")
    |> push_navigate(to: ~p"/agent/agents")
  end

  defp after_agent_save(%{assigns: %{live_action: :config}} = socket, %AgentConfig{} = agent) do
    assign(socket,
      agent: agent,
      browser_config_baseline: agent.config || %{},
      agents: AgentConfigs.list(),
      selected_skill_ids: AgentSkills.list_skill_ids(agent.id),
      form_revision: socket.assigns.form_revision + 1
    )
    |> reset_react_form(
      "agent-config-form",
      agent_form_values(agent, AgentSkills.list_skill_ids(agent.id))
    )
    |> put_flash(:info, "Agent saved")
  end

  defp after_agent_save(socket, _agent), do: put_flash(socket, :info, "Agent saved")

  defp save_browser_agent(attrs, params, socket, db_agent) do
    config =
      case db_agent do
        nil ->
          attrs["config"]

        agent ->
          case Map.fetch(agent.config || %{}, "browser") do
            {:ok, browser} -> Map.put(attrs["config"], "browser", browser)
            :error -> Map.delete(attrs["config"], "browser")
          end
      end

    with :ok <- validate_deferred_tools(config, attrs, socket, db_agent),
         {:ok, config} <-
           BrowserSettings.apply_config(
             config,
             socket.assigns.browser_config_baseline,
             params["browser_settings"]
           ) do
      attrs = Map.put(attrs, "config", config)
      if db_agent, do: AgentConfigs.update(db_agent, attrs), else: AgentConfigs.create(attrs)
    else
      {:error, {:deferred_tools, _message}} = error ->
        error

      {:error, message} ->
        {:error, {:browser_settings, message}}
    end
  end

  defp normalize_agent_attrs(attrs, agent) do
    {workspace_path, attrs} = Map.pop(attrs, "workspace_path")

    attrs
    |> merge_provider_model_state()
    |> merge_fallback_model_state()
    |> Map.delete("provider_model_state")
    |> Map.delete("fallback_model_state")
    |> Map.delete("web_allowed_hosts")
    |> Map.delete("deferred_tool_names")
    |> normalize_toolset_attrs(agent)
    |> normalize_blank("provider")
    |> normalize_blank("model")
    |> normalize_blank("toolset_id")
    |> normalize_permission_mode(agent)
    |> Map.put("config", workspace_config(agent, attrs, workspace_path))
    |> Map.update("enabled", false, &(&1 in ["true", "on", true]))
    |> Map.update("read_only", false, &(&1 in ["true", "on", true]))
  end

  defp preview_agent(%AgentConfig{} = agent, attrs, providers) do
    attrs = attrs |> merge_fallback_model_state() |> normalize_toolset_attrs(agent)
    provider = normalize_form_value(Map.get(attrs, "provider", agent.provider))
    models = models_for_provider(providers, provider)
    model = normalize_form_value(Map.get(attrs, "model", agent.model))

    model =
      if model_supported?(model, models) do
        model
      else
        nil
      end

    %{
      agent
      | name: Map.get(attrs, "name", agent.name),
        label: Map.get(attrs, "label", agent.label),
        icon: Map.get(attrs, "icon", agent.icon),
        description: Map.get(attrs, "description", agent.description),
        provider: provider,
        model: model,
        fallback_models: Map.get(attrs, "fallback_models", agent.fallback_models),
        reasoning_effort: Map.get(attrs, "reasoning_effort", agent.reasoning_effort),
        model_tier: Map.get(attrs, "model_tier", agent.model_tier),
        max_tokens: Map.get(attrs, "max_tokens", agent.max_tokens),
        toolset_ids: preview_toolset_ids(agent, attrs),
        toolset_id: preview_legacy_toolset_id(agent, attrs),
        permission_mode:
          permission_mode(Map.get(attrs, "permission_mode", agent.permission_mode)),
        enabled: Map.get(attrs, "enabled", agent.enabled) in ["true", "on", true],
        read_only: Map.get(attrs, "read_only", agent.read_only) in ["true", "on", true],
        config: workspace_config(agent, attrs, Map.get(attrs, "workspace_path"))
    }
  end

  defp preview_agent(agent, _attrs, _providers), do: agent

  defp normalize_form_value(value) when value in [nil, ""], do: nil
  defp normalize_form_value(value), do: value

  defp normalize_blank(attrs, key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      _ -> attrs
    end
  end

  defp normalize_toolset_attrs(%{"toolset_ids" => raw_ids} = attrs, agent) do
    submitted = normalize_toolset_ids(raw_ids)
    previous = selected_toolset_ids(agent)

    {toolset_ids, toolset_id} =
      if MapSet.new(submitted) == MapSet.new(previous) do
        {agent.toolset_ids || [], agent.toolset_id}
      else
        ids = reconcile_selection(raw_toolset_ids(agent), submitted)
        {ids, List.first(ids)}
      end

    attrs
    |> Map.put("toolset_ids", toolset_ids)
    |> Map.put("toolset_id", toolset_id || "")
  end

  defp normalize_toolset_attrs(%{"toolset_id" => toolset_id} = attrs, _agent) do
    case normalize_form_value(toolset_id) do
      nil -> Map.put(attrs, "toolset_ids", [])
      id -> Map.put(attrs, "toolset_ids", [id])
    end
  end

  defp normalize_toolset_attrs(attrs, _agent), do: attrs

  defp normalize_toolset_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp preview_toolset_ids(%AgentConfig{}, %{"toolset_ids" => ids}) do
    ids
  end

  defp preview_toolset_ids(%AgentConfig{toolset_ids: ids}, _attrs), do: ids

  defp preview_legacy_toolset_id(%AgentConfig{}, %{"toolset_id" => id}),
    do: normalize_form_value(id)

  defp preview_legacy_toolset_id(%AgentConfig{} = agent, _attrs), do: agent.toolset_id

  defp merge_provider_model_state(attrs) do
    case decode_provider_model_state(Map.get(attrs, "provider_model_state")) do
      {:ok, state} ->
        attrs
        |> merge_provider_model_value("provider", Map.get(state, "provider"))
        |> merge_provider_model_value("model", Map.get(state, "model"))

      :error ->
        attrs
    end
  end

  defp merge_provider_model_value(attrs, key, state_value) do
    case {normalize_form_value(Map.get(attrs, key)), normalize_form_value(state_value)} do
      {nil, nil} -> attrs
      {nil, value} -> Map.put(attrs, key, value)
      {_value, _state_value} -> attrs
    end
  end

  defp decode_provider_model_state(value) when is_binary(value) and value != "" do
    case Jason.decode(value) do
      {:ok, %{} = state} -> {:ok, state}
      _ -> :error
    end
  end

  defp decode_provider_model_state(_value), do: :error

  defp merge_fallback_model_state(attrs) do
    case decode_provider_model_state(Map.get(attrs, "fallback_model_state")) do
      {:ok, state} ->
        merge_fallback_model_value(attrs, fallback_models_from_state(state))

      :error ->
        attrs
    end
  end

  defp merge_fallback_model_value(attrs, state_value) do
    case {normalize_form_value(Map.get(attrs, "fallback_models")),
          normalize_form_value(state_value)} do
      {nil, nil} -> attrs
      {nil, value} -> Map.put(attrs, "fallback_models", value)
      {_value, _state_value} -> attrs
    end
  end

  defp fallback_models_from_state(%{"fallbackModels" => models}) when is_list(models) do
    models
    |> normalize_model_ids()
    |> Enum.join(", ")
  end

  defp fallback_models_from_state(%{"provider" => provider, "model" => model}) do
    provider = normalize_form_value(provider)
    model = normalize_form_value(model)

    if provider && model, do: "#{provider}/#{model}"
  end

  defp fallback_models_from_state(%{"model" => model}) when is_binary(model), do: model
  defp fallback_models_from_state(_state), do: nil

  defp normalize_permission_mode(attrs, agent) do
    existing_mode = if match?(%AgentConfig{}, agent), do: agent.permission_mode, else: nil
    mode = permission_mode(Map.get(attrs, "permission_mode", existing_mode))
    Map.put(attrs, "permission_mode", mode)
  end

  defp delete_agent(socket, %AgentConfig{} = agent, confirmation) do
    expected = delete_confirmation(agent)

    cond do
      AgentConfigs.protected?(agent) ->
        {:noreply, put_flash(socket, :error, "Default agents cannot be removed")}

      confirmation != expected ->
        {:noreply, put_flash(socket, :error, "Type #{expected} to confirm")}

      true ->
        case AgentConfigs.delete(agent) do
          {:ok, _agent} ->
            {:noreply,
             socket
             |> put_flash(:info, "Agent removed")
             |> push_navigate(to: ~p"/agent/agents")}

          {:error, :protected} ->
            {:noreply, put_flash(socket, :error, "Default agents cannot be removed")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to remove agent")}
        end
    end
  end

  defp move_wizard(socket, offset) do
    active_tab = socket.assigns.active_config_tab
    current_index = Enum.find_index(@wizard_steps, &(&1 == active_tab)) || 0
    next_index = current_index + offset
    bounded_index = max(0, min(next_index, length(@wizard_steps) - 1))

    assign(socket, active_config_tab: Enum.at(@wizard_steps, bounded_index), wizard_mode: true)
  end

  defp config_tabs(:new) do
    [
      {"Overview", "overview", "view-dashboard-outline"},
      {"Workspace", "workspace", "folder-outline"},
      {"Runtime", "runtime", "tune-variant"},
      {"Tools", "tools", "tools"},
      {"Skills", "skills", "lightning-bolt"},
      {"Prompt", "prompt", "text-box-outline"}
    ]
  end

  defp config_tabs(_action),
    do: config_tabs(:new) ++ [{"Management", "management", "cog-outline"}]

  defp wizard_step_index(active_tab) do
    case Enum.find_index(@wizard_steps, &(&1 == active_tab)) do
      nil -> 0
      index -> index + 1
    end
  end

  defp wizard_step_label("overview"), do: "Overview"
  defp wizard_step_label("workspace"), do: "Workspace"
  defp wizard_step_label("runtime"), do: "Runtime"
  defp wizard_step_label("tools"), do: "Tools"
  defp wizard_step_label("skills"), do: "Skills"
  defp wizard_step_label("prompt"), do: "System Prompt"
  defp wizard_step_label(_tab), do: "Configuration"

  defp deletable_agent?(%AgentConfig{} = agent), do: !AgentConfigs.protected?(agent)
  defp deletable_agent?(_agent), do: false

  defp tab_panel_class(active_tab, tab) do
    [
      "rounded-lg border border-outline-variant bg-surface-container p-5",
      if(active_tab == tab, do: nil, else: "hidden")
    ]
  end

  defp workspace_config(agent, attrs, submitted_path) do
    agent
    |> agent_config_map()
    |> Map.put("workspace_path", normalize_workspace_path(submitted_path, agent, attrs))
    |> web_fetch_config(attrs)
    |> deferred_tools_config(attrs)
  end

  defp deferred_tools_config(config, %{"deferred_tool_names" => submitted})
       when is_list(submitted) do
    submitted = Enum.reject(submitted, &(&1 == ""))
    previous = Map.get(config, "deferred_tool_names", [])

    if is_list(previous) do
      names =
        Enum.filter(previous, &(&1 in submitted)) ++
          Enum.reject(submitted, &(&1 in previous))

      if names == [] and not Map.has_key?(config, "deferred_tool_names"),
        do: config,
        else: Map.put(config, "deferred_tool_names", names)
    else
      # An unrelated save must not reinterpret an unavailable saved value.
      if submitted == [], do: config, else: Map.put(config, "deferred_tool_names", submitted)
    end
  end

  defp deferred_tools_config(config, %{"deferred_tool_names" => value}),
    do: Map.put(config, "deferred_tool_names", value)

  defp deferred_tools_config(config, _attrs), do: config

  defp deferred_tool_names(agent) do
    case agent_config_map(agent)["deferred_tool_names"] do
      names when is_list(names) -> Enum.filter(names, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  defp deferred_tool_choices(agent, toolsets, groups, policy) do
    names = selected_deferred_tool_names(agent, toolsets, groups, policy)
    available = Enum.map(names, &%{name: &1, available: true})

    unavailable =
      agent
      |> deferred_tool_names()
      |> Enum.reject(&(&1 in names))
      |> Enum.uniq()
      |> Enum.map(&%{name: &1, available: false})

    available ++ unavailable
  end

  defp selected_deferred_tool_names(agent, toolsets, groups, policy) do
    if native_tool_selection?(agent, toolsets) do
      known = MapSet.new(Synapsis.Agent.Tools.DisplayCatalog.list(), & &1.name)

      builtins =
        agent
        |> agent_tool_names(selected_toolsets(agent, toolsets))
        |> Enum.filter(&MapSet.member?(known, &1))

      mcp =
        Enum.flat_map(groups, fn group ->
          mode = if group.mode == "inherit", do: policy["default"], else: group.mode

          if group.enabled and group.status == :available do
            group.tools
            |> Enum.filter(
              &(&1.available and
                  (mode == "all" or
                     (mode == "selected" and &1.name in group.selected)))
            )
            |> Enum.map(&"mcp::#{group.id}::#{&1.name}")
          else
            []
          end
        end)

      Enum.uniq(builtins ++ mcp)
    else
      []
    end
  end

  defp validate_deferred_tools(config, attrs, socket, db_agent) do
    names = Map.get(config, "deferred_tool_names", [])
    saved = if db_agent, do: Map.get(db_agent.config || %{}, "deferred_tool_names", []), else: []

    if names === saved do
      :ok
    else
      agent = %{
        socket.assigns.agent
        | toolset_ids: attrs["toolset_ids"] || socket.assigns.agent.toolset_ids,
          toolset_id: normalize_form_value(attrs["toolset_id"]),
          config: config
      }

      policy = mcp_normalize_policy(config["mcp_selection"])
      groups = mcp_groups(socket.assigns.mcp_sources, socket.assigns.mcp_catalog, policy)
      selected = selected_deferred_tool_names(agent, socket.assigns.toolsets, groups, policy)
      retained = if is_list(saved), do: saved, else: []

      if is_list(names) and Enum.all?(names, &(is_binary(&1) and &1 != "")) and
           length(Enum.uniq(names)) == length(names) and
           Enum.all?(names, &(&1 in selected or &1 in retained)) do
        :ok
      else
        {:error,
         {:deferred_tools, "Deferred tools must be unique names from the selected tools."}}
      end
    end
  end

  defp web_fetch_config(config, %{"web_allowed_hosts" => value}) when is_binary(value) do
    if value == web_allowed_hosts_text(config) do
      config
    else
      hosts =
        value |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      case hosts do
        [] -> Map.delete(config, "web_allowed_hosts")
        hosts -> Map.put(config, "web_allowed_hosts", hosts)
      end
    end
  end

  defp web_fetch_config(config, _attrs), do: config

  # React keeps typed drafts, but its event adapter stringifies scalar values.
  defp web_fetch_form_attrs(attrs, socket) do
    case react_form_draft(socket.assigns, "agent-config-form") do
      %{"agent" => %{"web_allowed_hosts" => value}}
      when is_nil(value) or is_boolean(value) or is_number(value) ->
        submitted = if is_nil(value), do: "", else: to_string(value)

        if Map.get(attrs, "web_allowed_hosts") == submitted,
          do: Map.put(attrs, "web_allowed_hosts", value),
          else: attrs

      _ ->
        attrs
    end
  end

  defp web_allowed_hosts_value(agent) do
    agent |> agent_config_map() |> web_allowed_hosts_text()
  end

  defp web_allowed_hosts_text(config) do
    case config["web_allowed_hosts"] do
      hosts when is_list(hosts) -> hosts |> Enum.filter(&is_binary/1) |> Enum.join("\n")
      _ -> ""
    end
  end

  defp normalize_workspace_path(path, agent, attrs) when path in [nil, ""] do
    default_workspace_path(agent, attrs)
  end

  defp normalize_workspace_path(path, _agent, _attrs), do: String.trim(path)

  defp workspace_path(%AgentConfig{} = agent) do
    case agent_config_map(agent)["workspace_path"] do
      path when is_binary(path) and path != "" -> path
      _ -> default_workspace_path(agent, %{})
    end
  end

  defp workspace_path(_agent), do: default_workspace_path(nil, %{})

  defp default_workspace_path(%AgentConfig{name: name}, _attrs) when name not in [nil, ""] do
    "~/.synapsis/agents/#{name}"
  end

  defp default_workspace_path(_agent, %{"name" => name}) when name not in [nil, ""] do
    "~/.synapsis/agents/#{name}"
  end

  defp default_workspace_path(_agent, _attrs), do: "~/.synapsis/agents/new-agent"

  defp agent_config_map(%AgentConfig{config: config}) when is_map(config) do
    Map.new(config, fn {key, value} -> {to_string(key), value} end)
  end

  defp agent_config_map(_agent), do: %{}

  defp delete_confirmation(%AgentConfig{name: name}) when name not in [nil, ""] do
    "delete agent #{name}"
  end

  defp delete_confirmation(_agent), do: "delete agent"

  defp load_providers do
    Providers.configured_models()
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {name, models} ->
      %{name: name, models: Enum.map(models, &%{id: &1.model, name: &1.name})}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp provider_model_cascader_options(providers) do
    providers
    |> Enum.map(fn provider ->
      provider_id = provider_name(provider)

      %{
        value: provider_id,
        label: provider_label(provider),
        children:
          providers
          |> models_for_provider(provider_id)
          |> Enum.map(&%{value: model_id(&1), label: model_label(&1)})
      }
    end)
  end

  defp provider_model_state_value(%AgentConfig{} = agent) do
    Jason.encode!(%{
      provider: agent.provider || "",
      model: agent.model || ""
    })
  end

  defp fallback_model_state_value(%AgentConfig{} = agent) do
    {provider, model} = backup_provider_model(agent.fallback_models)

    Jason.encode!(%{
      provider: provider || "",
      model: model || ""
    })
  end

  defp backup_provider_model(fallbacks) do
    case fallback_tokens(fallbacks) do
      [token | _rest] -> split_provider_model(token)
      [] -> {nil, nil}
    end
  end

  defp split_provider_model(token) when is_binary(token) do
    case String.split(token, "/", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {provider, model}
      _ -> {nil, nil}
    end
  end

  defp split_provider_model(_token), do: {nil, nil}

  defp models_for_provider(_providers, nil), do: []
  defp models_for_provider(_providers, ""), do: []

  defp models_for_provider(providers, provider_name) do
    case Enum.find(providers, &(&1.name == provider_name)) do
      nil -> []
      provider -> provider.models
    end
  end

  defp normalize_model_ids(model_ids) do
    model_ids
    |> Enum.map(&model_id/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp model_supported?(nil, _models), do: true
  defp model_supported?("", _models), do: true
  defp model_supported?(model, models), do: Enum.any?(models, &(model_id(&1) == model))

  defp provider_name(%{name: name}), do: name
  defp provider_name(%{"name" => name}), do: name

  defp provider_label(provider), do: provider_name(provider)

  defp model_id(model) when is_binary(model), do: model
  defp model_id(%{id: id}), do: id
  defp model_id(%{"id" => id}), do: id
  defp model_id(model), do: to_string(model)

  defp model_label(%{name: name, id: id}) when name != id, do: "#{name} (#{id})"
  defp model_label(%{"name" => name, "id" => id}) when name != id, do: "#{name} (#{id})"
  defp model_label(%{name: name}), do: name
  defp model_label(%{"name" => name}), do: name
  defp model_label(model) when is_binary(model), do: model
  defp model_label(%{id: id}), do: id
  defp model_label(%{"id" => id}), do: id
  defp model_label(model), do: to_string(model)

  defp selected_toolsets(%AgentConfig{} = agent, toolsets) do
    ids = selected_toolset_ids(agent)
    by_id = Map.new(toolsets, &{&1.id, &1})

    Enum.flat_map(ids, fn id ->
      case Map.get(by_id, id) do
        nil -> []
        toolset -> [toolset]
      end
    end)
  end

  defp selected_toolset_ids(agent), do: agent |> raw_toolset_ids() |> normalize_toolset_ids()

  defp raw_toolset_ids(%AgentConfig{toolset_ids: ids}) when is_list(ids) and ids != [], do: ids

  defp raw_toolset_ids(%AgentConfig{toolset_id: id}) when not is_nil(id) and id != "",
    do: [id]

  defp raw_toolset_ids(_agent), do: []

  # Checkboxes express membership once per name. Retain the saved ordering and
  # occurrences for names still selected, and append genuinely new choices.
  defp reconcile_selection(previous, submitted) do
    submitted = normalize_toolset_ids(submitted)
    Enum.filter(previous, &(&1 in submitted)) ++ Enum.reject(submitted, &(&1 in previous))
  end

  defp agent_tool_names(agent, toolsets) do
    if selected_toolset_ids(agent) == [] do
      agent.tools || []
    else
      toolsets |> Enum.flat_map(&(&1.tool_names || [])) |> Enum.uniq()
    end
  end

  # Linked Toolsets replace direct tools. Their saved contracts determine the
  # effective selection even when the Agent record itself is still version 0.
  # This is display provenance only; runtime admission still checks raw records.
  defp native_tool_selection?(%AgentConfig{} = agent, toolsets) do
    case selected_toolset_ids(agent) do
      [] ->
        agent.tool_contract_version == 1

      ids ->
        selected = selected_toolsets(agent, toolsets)
        length(selected) == length(ids) and Enum.all?(selected, &(&1.tool_contract_version == 1))
    end
  end

  defp native_tool_selection?(_agent, _toolsets), do: false

  defp permission_mode_options do
    [
      {"yolo", "Yolo"},
      {"ask", "Ask for bash"},
      {"restrict", "Restrict"}
    ]
  end

  defp permission_mode(%AgentConfig{permission_mode: mode}), do: permission_mode(mode)
  defp permission_mode(mode) when mode in ["yolo", "ask", "restrict"], do: mode
  defp permission_mode(mode) when mode in [nil, ""], do: "yolo"
  defp permission_mode(_mode), do: "ask"

  defp agent_label(%AgentConfig{name: nil, label: nil}), do: "Agent"
  defp agent_label(%AgentConfig{label: label}) when label not in [nil, ""], do: label
  defp agent_label(%AgentConfig{name: name}), do: String.capitalize(name)

  defp agent_option_label(%AgentConfig{} = agent) do
    suffix = if agent.is_default, do: " (default)", else: ""
    "#{agent_label(agent)}#{suffix}"
  end

  defp model_summary(%AgentConfig{provider: provider, model: model} = agent) do
    base =
      cond do
        provider not in [nil, ""] and model not in [nil, ""] -> "#{provider}/#{model}"
        model not in [nil, ""] -> model
        true -> "-"
      end

    case fallback_count(agent.fallback_models) do
      0 -> base
      count -> "#{base} (+#{count} backup)"
    end
  end

  defp runtime_summary(%AgentConfig{} = agent) do
    mode = if agent.read_only, do: "read-only", else: "write-enabled"
    effort = agent.reasoning_effort || "medium"
    "#{mode}, #{effort} reasoning"
  end

  defp maybe_refresh_mcp(socket) do
    cond do
      native_tool_selection?(socket.assigns.agent, socket.assigns.toolsets) ->
        assign_mcp_catalog(socket)

      socket.assigns.mcp_loading ->
        socket

      connected?(socket) and socket.assigns.live_action in [:new, :config] ->
        socket
        |> assign(mcp_loading: true)
        |> start_async(:agent_mcp_catalog, fn -> Synapsis.MCPSelection.refresh() end)

      true ->
        socket
    end
  end

  defp assign_mcp_catalog(socket) do
    if native_tool_selection?(socket.assigns.agent, socket.assigns.toolsets),
      do: assign_native_mcp_catalog(socket),
      else: assign_legacy_mcp_catalog(socket)
  end

  defp assign_native_mcp_catalog(socket) do
    {catalog, sources} =
      Synapsis.MCPConfigs.list()
      |> Enum.map(fn source ->
        snapshot =
          if Synapsis.MCPConfigs.runtime_available?(source),
            do: Synapsis.MCP.runtime_snapshot(source.id),
            else: {:error, :disabled}

        {tools, status} =
          case snapshot do
            {:ok, %{source_id: id, tools: tools}} when id == source.id ->
              {Enum.map(tools, fn tool ->
                 %{mcp_config_id: source.id, mcp_tool_name: tool.raw_name}
               end), :available}

            _ ->
              {[], if(source.enabled, do: :unavailable, else: :disabled)}
          end

        {tools, Map.put(source, :runtime_status, status)}
      end)
      |> Enum.unzip()

    assign(socket, mcp_catalog: List.flatten(catalog), mcp_sources: sources)
  end

  defp assign_legacy_mcp_catalog(socket) do
    assign(socket,
      mcp_catalog: Synapsis.MCPSelection.display_catalog(),
      mcp_sources: Synapsis.MCPConfigs.list()
    )
  end

  defp mcp_initialize_policy(agent, sources) do
    config = agent.config || %{}

    if Map.has_key?(config, "mcp_selection") do
      agent
    else
      toolsets = Toolsets.list()

      policy =
        if native_tool_selection?(agent, toolsets) do
          agent
          |> agent_tool_names(selected_toolsets(agent, toolsets))
          |> native_mcp_policy()
        else
          names = Synapsis.Agent.Resolver.resolve(agent.name).tools
          Synapsis.MCPSelection.from_legacy(names, sources)
        end

      %{agent | config: Map.put(config, "mcp_selection", policy)}
    end
  end

  defp native_mcp_policy(names) do
    sources =
      Enum.reduce(names, %{}, fn
        "mcp::" <> qualified, sources ->
          case String.split(qualified, "::", parts: 2) do
            [id, raw] when raw != "" ->
              if Ecto.UUID.cast(id) == {:ok, id} do
                Map.update(sources, id, %{"mode" => "selected", "tools" => [raw]}, fn rule ->
                  Map.update!(rule, "tools", &(&1 ++ [raw]))
                end)
              else
                sources
              end

            _ ->
              sources
          end

        _, sources ->
          sources
      end)

    %{"default" => "selected", "sources" => sources}
  end

  defp mcp_preview(agent, params) do
    case Map.fetch(params, "mcp_selection") do
      {:ok, policy} ->
        %{
          agent
          | config:
              Map.put(
                agent.config || %{},
                "mcp_selection",
                mcp_normalize_policy(policy, (agent.config || %{})["mcp_selection"])
              )
        }

      :error ->
        agent
    end
  end

  defp mcp_normalize_policy(policy, previous \\ nil)

  defp mcp_normalize_policy(%{"default" => default} = policy, previous)
       when default in ["all", "selected"] do
    sources =
      case policy["sources"] do
        sources when is_map(sources) ->
          Map.new(sources, fn {id, rule} ->
            mode = if is_map(rule), do: rule["mode"], else: "none"
            names = if is_map(rule), do: List.wrap(rule["tools"]), else: []
            names = Enum.filter(names, &(is_binary(&1) and &1 != ""))

            prior_rule = get_in(previous || %{}, ["sources", id])

            names =
              if is_map(prior_rule),
                do: reconcile_selection(List.wrap(prior_rule["tools"]), names),
                else: names

            {id,
             %{
               "mode" => mode,
               "tools" => names
             }}
          end)
          |> Map.reject(fn {_id, rule} -> rule["mode"] in [nil, "", "inherit"] end)

        _ ->
          %{}
      end

    %{"default" => default, "sources" => sources}
  end

  defp mcp_normalize_policy(_, _), do: %{"default" => "selected", "sources" => %{}}

  defp mcp_form_policy(policy) do
    policy = mcp_normalize_policy(policy)

    sources =
      Enum.reduce(Synapsis.MCPConfigs.list(), policy["sources"], fn source, sources ->
        Map.put_new(sources, source.id, %{"mode" => "inherit", "tools" => []})
      end)

    Map.put(policy, "sources", sources)
  end

  defp mcp_groups(sources, catalog, policy) do
    configured_ids = Enum.map(sources, & &1.id)

    unavailable_sources =
      policy["sources"]
      |> Map.keys()
      |> Enum.reject(&(&1 in configured_ids))
      |> Enum.sort()
      |> Enum.map(&%{id: &1, name: &1, enabled: false, unavailable: true})

    sources = Enum.map(sources, &Map.put(&1, :unavailable, false)) ++ unavailable_sources

    Enum.map(sources, fn source ->
      rule = policy["sources"][source.id] || %{}
      selected = rule["tools"] || []

      available =
        if source.unavailable do
          []
        else
          catalog |> Enum.filter(&(&1.mcp_config_id == source.id)) |> Enum.map(& &1.mcp_tool_name)
        end

      tools =
        Enum.sort(Enum.uniq(available ++ selected))
        |> Enum.map(&%{name: &1, available: &1 in available})

      %{
        id: source.id,
        name: source.name,
        enabled: source.enabled,
        unavailable: source.unavailable,
        status:
          cond do
            source.unavailable -> :unavailable
            not source.enabled -> :disabled
            true -> Map.get(source, :runtime_status)
          end,
        mode: rule["mode"] || "inherit",
        selected: selected,
        tools: tools
      }
    end)
  end

  defp skill_source_groups(skills) do
    sources = Map.new(Synapsis.Backplane.Connection.list(), &{&1.id, &1})

    skills
    |> Enum.group_by(&((&1.config_overrides || %{})["backplane_source_id"] || "local"))
    |> Enum.map(fn {id, grouped} ->
      label =
        case sources[id] do
          nil ->
            if id == "local", do: "Local skills", else: "Remote source " <> id

          source ->
            case Synapsis.Backplane.ProviderSource.get(source.provider_id, allow_disabled: true) do
              {:ok, resolved} -> resolved.provider.name
              _ -> source.name
            end
        end

      %{id: id, label: label, skills: grouped}
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp skills_summary(0), do: "all skills"
  defp skills_summary(count), do: "#{count} assigned"

  defp fallback_count(fallbacks), do: fallbacks |> fallback_tokens() |> length()

  defp fallback_tokens(nil), do: []
  defp fallback_tokens(""), do: []

  defp fallback_tokens(fallbacks) when is_binary(fallbacks) do
    fallbacks
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp fallback_tokens(_fallbacks), do: []

  defp save_error(%Ecto.Changeset{}), do: "Failed to save agent"
  defp save_error({:deferred_tools, message}), do: message
  defp save_error(:unsupported_action), do: "Unsupported agent action"
  defp save_error(_reason), do: "Failed to save agent"
end
