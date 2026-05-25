defmodule SynapsisWeb.AgentLive.Agents do
  @moduledoc "Agent module page for managing agent configurations."
  use SynapsisWeb, :live_view

  import SynapsisWeb.AgentLive.Components

  alias Synapsis.{AgentConfig, AgentConfigs, AgentSkills, Providers, Skills, Toolsets}
  alias Synapsis.Provider.ModelRegistry

  @config_tabs ~w(overview workspace runtime tools skills prompt management)
  @wizard_steps ~w(overview workspace runtime tools skills prompt)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Agents",
       agent: nil,
       selected_skill_ids: [],
       agents: [],
       skills: [],
       toolsets: [],
       providers: [],
       active_config_tab: "overview",
       wizard_mode: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign_common()
      |> apply_action(socket.assigns.live_action, params)

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
            {:noreply,
             socket
             |> assign(agent: updated_agent, agents: AgentConfigs.list())
             |> put_flash(:info, if(enabled?, do: "Agent enabled", else: "Agent disabled"))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update agent")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("change_agent_form", %{"agent" => attrs}, socket) do
    {:noreply,
     assign(socket, agent: preview_agent(socket.assigns.agent, attrs, socket.assigns.providers))}
  end

  def handle_event("save_agent", %{"agent" => attrs} = params, socket) do
    skill_ids = params |> Map.get("skill_ids", []) |> List.wrap()
    attrs = normalize_agent_attrs(attrs, socket.assigns.agent)

    result =
      case socket.assigns.live_action do
        :new -> AgentConfigs.create(attrs)
        :config -> AgentConfigs.update(socket.assigns.agent, attrs)
        _ -> {:error, :unsupported_action}
      end

    case result do
      {:ok, %AgentConfig{} = agent} ->
        {:ok, _skills} = AgentSkills.assign_skills(agent, skill_ids)

        {:noreply, after_agent_save(socket, agent)}

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
          selected_skill_ids={@selected_skill_ids}
          action={@live_action}
          active_tab={@active_config_tab}
          wizard_mode={@wizard_mode}
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
  attr :selected_skill_ids, :list, required: true
  attr :active_tab, :string, required: true
  attr :wizard_mode, :boolean, required: true

  defp agent_form(assigns) do
    selected_toolset = selected_toolset(assigns.agent, assigns.toolsets)
    tool_names = agent_tool_names(assigns.agent, selected_toolset)
    fallback_tokens = fallback_tokens(assigns.agent.fallback_models)
    workspace_path = workspace_path(assigns.agent)
    permission_mode = permission_mode(assigns.agent)

    assigns =
      assigns
      |> assign(:selected_toolset, selected_toolset)
      |> assign(:tool_names, tool_names)
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
              form="agent-config-form"
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
          <.dm_form
            for={%{}}
            as={:agent}
            id="agent-config-form"
            phx-submit="save_agent"
            phx-change="change_agent_form"
            class={if @active_tab == "management", do: "hidden", else: "space-y-5"}
          >
            <section class={tab_panel_class(@active_tab, "overview")}>
              <div class="mb-5">
                <h3 class="text-lg font-semibold">Overview</h3>
                <p class="text-sm text-on-surface-variant">
                  Identity, model routing, and assignment metadata.
                </p>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4 mb-6">
                <.overview_metric label="Agent ID" value={@agent.id || "pending"} mono />
                <.overview_metric label="Primary Model" value={model_summary(@agent)} mono />
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
                <.dm_input type="text" name="agent[label]" value={@agent.label} label="Label" />
                <.dm_input type="text" name="agent[icon]" value={@agent.icon} label="Icon" />
                <div class="form-group">
                  <label for="agent-provider-model-picker-provider" class="form-label">
                    <span>Provider / model</span>
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
                <.dm_textarea
                  name="agent[description]"
                  value={@agent.description}
                  rows={2}
                  label="Description"
                  resize="none"
                />
              </div>

              <div class="mt-5">
                <div class="text-xs text-on-surface-variant mb-3">Fallback Models</div>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <.dm_input
                    type="text"
                    name="agent[fallback_models]"
                    value={@agent.fallback_models}
                    label="Fallbacks"
                    placeholder="gpt-4o, o3"
                  />
                </div>
                <div :if={@fallback_tokens != []} class="flex flex-wrap gap-2 mt-3">
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
                  name="agent[toolset_id]"
                  label="Toolset"
                  options={[{"", "Legacy/custom tools"} | Enum.map(@toolsets, &{&1.id, &1.name})]}
                  value={@agent.toolset_id || ""}
                />

                <.dm_select
                  name="agent[permission_mode]"
                  label="Permission mode"
                  options={permission_mode_options()}
                  value={@permission_mode}
                />
              </div>

              <div :if={@selected_toolset} class="mt-3 text-sm text-on-surface-variant">
                {@selected_toolset.description}
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
              <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                <label
                  :for={skill <- @skills}
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
                <div :if={@skills == []} class="text-sm text-on-surface-variant">
                  No skills have been configured yet.
                </div>
              </div>
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
          </.dm_form>

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

              <.dm_form
                :if={deletable_agent?(@agent)}
                for={%{}}
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
              </.dm_form>

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
      providers: load_providers()
    )
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Agents", agent: nil, selected_skill_ids: [], wizard_mode: false)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Agent",
      agent: %AgentConfig{enabled: true, icon: "robot-outline"},
      selected_skill_ids: [],
      active_config_tab: "overview",
      wizard_mode: false
    )
  end

  defp apply_action(socket, :config, %{"id" => id}) do
    case AgentConfigs.get(id) do
      %AgentConfig{} = agent ->
        assign(socket,
          page_title: "Agent Config",
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

  defp after_agent_save(%{assigns: %{live_action: :new}} = socket, _agent) do
    socket
    |> put_flash(:info, "Agent saved")
    |> push_navigate(to: ~p"/agent/agents")
  end

  defp after_agent_save(%{assigns: %{live_action: :config}} = socket, %AgentConfig{} = agent) do
    assign(socket,
      agent: agent,
      agents: AgentConfigs.list(),
      selected_skill_ids: AgentSkills.list_skill_ids(agent.id)
    )
    |> put_flash(:info, "Agent saved")
  end

  defp after_agent_save(socket, _agent), do: put_flash(socket, :info, "Agent saved")

  defp normalize_agent_attrs(attrs, agent) do
    {workspace_path, attrs} = Map.pop(attrs, "workspace_path")

    attrs
    |> merge_provider_model_state()
    |> Map.delete("provider_model_state")
    |> normalize_blank("provider")
    |> normalize_blank("model")
    |> normalize_blank("toolset_id")
    |> normalize_permission_mode(agent)
    |> Map.put("config", workspace_config(agent, attrs, workspace_path))
    |> Map.update("enabled", false, &(&1 in ["true", "on", true]))
    |> Map.update("read_only", false, &(&1 in ["true", "on", true]))
  end

  defp preview_agent(%AgentConfig{} = agent, attrs, providers) do
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
    case Providers.list(enabled: true) do
      {:ok, list} -> list
      list when is_list(list) -> list
      _ -> []
    end
    |> Enum.uniq_by(&provider_name/1)
    |> Enum.sort_by(&provider_name/1)
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

  defp models_for_provider(_providers, nil), do: []
  defp models_for_provider(_providers, ""), do: []

  defp models_for_provider(providers, provider_name) do
    provider = Enum.find(providers, &(provider_name(&1) == provider_name))

    provider_configured_models(provider)
    |> case do
      [] -> registry_models_for_provider(provider_name, provider)
      models -> models
    end
    |> filter_enabled_models(provider)
  end

  defp registry_models_for_provider(provider_name, provider) do
    provider_name
    |> provider_model_keys(provider)
    |> Enum.find_value([], fn key ->
      case ModelRegistry.list(key) do
        [] -> nil
        models -> models
      end
    end)
  end

  defp filter_enabled_models(models, nil), do: models

  defp filter_enabled_models(models, provider) do
    case Providers.enabled_models(provider) do
      [] -> models
      enabled_models -> models_for_enabled_ids(models, enabled_models)
    end
  end

  defp models_for_enabled_ids(models, enabled_models) do
    models_by_id = Map.new(models, &{model_id(&1), &1})

    enabled_models
    |> normalize_model_ids()
    |> Enum.map(fn id -> Map.get(models_by_id, id, %{id: id, name: id}) end)
  end

  defp provider_configured_models(nil), do: []

  defp provider_configured_models(provider) do
    provider
    |> provider_config_map()
    |> Map.get("models", [])
    |> normalize_configured_models()
  end

  defp provider_config_map(%{config: config}) when is_map(config) do
    Map.new(config, fn {key, value} -> {to_string(key), value} end)
  end

  defp provider_config_map(%{"config" => config}) when is_map(config) do
    Map.new(config, fn {key, value} -> {to_string(key), value} end)
  end

  defp provider_config_map(_provider), do: %{}

  defp normalize_configured_models(models) when is_list(models) do
    models
    |> Enum.map(&normalize_configured_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&model_id/1)
  end

  defp normalize_configured_models(_models), do: []

  defp normalize_configured_model(model) when is_binary(model) do
    case String.trim(model) do
      "" -> nil
      id -> %{id: id, name: id}
    end
  end

  defp normalize_configured_model(%{id: id} = model),
    do: normalize_configured_model(id, model[:name])

  defp normalize_configured_model(%{"id" => id} = model),
    do: normalize_configured_model(id, model["name"])

  defp normalize_configured_model(_model), do: nil

  defp normalize_configured_model(id, name) do
    id = model_id(id)
    name = if name in [nil, ""], do: id, else: model_id(name)

    if id == "", do: nil, else: %{id: id, name: name}
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

  defp provider_model_keys(provider_name, nil), do: [provider_name]

  defp provider_model_keys(provider_name, provider) do
    [provider_name, provider_family(provider_name, provider), provider_type(provider)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp provider_family(provider_name, provider) do
    provider_hint =
      [provider_name, provider_base_url(provider)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(provider_hint, "moonshot") ->
        "moonshot"

      String.contains?(provider_hint, "zhipu") or String.contains?(provider_hint, "bigmodel") or
          String.contains?(provider_hint, "z.ai") ->
        "zhipu"

      String.contains?(provider_hint, "minimax") ->
        "minimax"

      true ->
        nil
    end
  end

  defp provider_name(%{name: name}), do: name
  defp provider_name(%{"name" => name}), do: name

  defp provider_type(%{type: type}), do: type
  defp provider_type(%{"type" => type}), do: type
  defp provider_type(_provider), do: nil

  defp provider_base_url(%{base_url: base_url}), do: base_url
  defp provider_base_url(%{"base_url" => base_url}), do: base_url
  defp provider_base_url(_provider), do: nil

  defp provider_label(provider) do
    case provider_type(provider) do
      nil -> provider_name(provider)
      type -> "#{provider_name(provider)} (#{type})"
    end
  end

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

  defp selected_toolset(%AgentConfig{toolset_id: nil}, _toolsets), do: nil
  defp selected_toolset(%AgentConfig{toolset_id: ""}, _toolsets), do: nil

  defp selected_toolset(%AgentConfig{toolset_id: toolset_id}, toolsets) do
    Enum.find(toolsets, &(&1.id == toolset_id))
  end

  defp agent_tool_names(%AgentConfig{} = agent, nil), do: agent.tools || []
  defp agent_tool_names(_agent, toolset), do: toolset.tool_names || []

  defp permission_mode_options do
    [
      {"yolo", "Yolo"},
      {"ask", "Ask for bash"},
      {"restrict", "Restrict"}
    ]
  end

  defp permission_mode(%AgentConfig{permission_mode: mode}), do: permission_mode(mode)
  defp permission_mode(mode) when mode in ["yolo", "ask", "restrict"], do: mode
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
      count -> "#{base} (+#{count} fallback)"
    end
  end

  defp runtime_summary(%AgentConfig{} = agent) do
    mode = if agent.read_only, do: "read-only", else: "write-enabled"
    effort = agent.reasoning_effort || "medium"
    "#{mode}, #{effort} reasoning"
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
  defp save_error(:unsupported_action), do: "Unsupported agent action"
  defp save_error(_reason), do: "Failed to save agent"
end
