defmodule SynapsisWeb.AgentLive.Skills do
  @moduledoc "Agent module page for managing skills and agent assignments."
  use SynapsisWeb, :live_view

  import SynapsisWeb.AgentLive.Components

  alias Synapsis.{AgentConfigs, AgentSkills, Skill, Skills}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Skills",
       skill: nil,
       skills: [],
       agents: [],
       selected_agent_ids: []
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
  def handle_event("save_skill", %{"skill" => attrs} = params, socket) do
    agent_ids = params |> Map.get("agent_ids", []) |> List.wrap()

    result =
      case socket.assigns.live_action do
        :new -> Skills.create(attrs)
        :edit -> Skills.update(socket.assigns.skill, attrs)
        _ -> {:error, :unsupported_action}
      end

    case result do
      {:ok, %Skill{} = skill} ->
        :ok = AgentSkills.assign_agents(skill, agent_ids)

        {:noreply,
         socket
         |> put_flash(:info, "Skill saved")
         |> push_navigate(to: ~p"/agent/skills")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save skill")}
    end
  end

  def handle_event("delete_skill", %{"id" => id}, socket) do
    with %Skill{} = skill <- Skills.get(id),
         {:ok, _} <- Skills.delete(skill) do
      {:noreply, socket |> assign_common() |> put_flash(:info, "Skill removed")}
    else
      {:error, :protected} ->
        {:noreply, put_flash(socket, :error, "Built-in skills cannot be removed")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.agent_shell active={:skills}>
      <div class="max-w-5xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold">Skills</h1>
            <p class="text-sm text-on-surface-variant">Create skills and assign them to agents.</p>
          </div>
          <.dm_link :if={@live_action == :index} navigate={~p"/agent/skills/new"}>
            <.dm_btn variant="primary" size="sm">
              <.dm_mdi name="plus" class="w-4 h-4" /> New Skill
            </.dm_btn>
          </.dm_link>
        </div>

        <.skill_form
          :if={@live_action in [:new, :edit]}
          skill={@skill}
          agents={@agents}
          selected_agent_ids={@selected_agent_ids}
        />

        <div :if={@live_action == :index} class="space-y-2">
          <.dm_card :for={skill <- @skills} variant="bordered">
            <div class="flex items-center justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <h2 class="font-semibold">{skill.name}</h2>
                  <.dm_badge
                    variant={if skill.scope == "global", do: "primary", else: "secondary"}
                    size="sm"
                  >
                    {skill.scope}
                  </.dm_badge>
                  <.dm_badge :if={skill.is_builtin} variant="warning" size="sm">built-in</.dm_badge>
                </div>
                <p class="text-xs text-on-surface-variant mt-1">{skill.description}</p>
              </div>
              <div class="flex items-center gap-1 shrink-0">
                <.dm_link navigate={~p"/agent/skills/#{skill.id}/edit"}>
                  <.dm_btn variant="ghost" size="xs">
                    <.dm_mdi name="pencil" class="w-3.5 h-3.5" /> Edit
                  </.dm_btn>
                </.dm_link>
                <.dm_btn
                  variant="ghost"
                  size="xs"
                  class="text-error"
                  phx-click="delete_skill"
                  phx-value-id={skill.id}
                  confirm="Remove this skill?"
                >
                  Remove
                </.dm_btn>
              </div>
            </div>
          </.dm_card>
        </div>

        <.empty_state
          :if={@live_action == :index && @skills == []}
          icon="lightning-bolt"
          title="No skills"
          description="Create a skill to add prompt behavior to agents."
        />
      </div>
    </.agent_shell>
    """
  end

  attr :skill, :map, required: true
  attr :agents, :list, required: true
  attr :selected_agent_ids, :list, required: true

  defp skill_form(assigns) do
    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>{if @skill.id, do: "Edit Skill", else: "New Skill"}</:title>

      <.dm_form for={%{}} as={:skill} phx-submit="save_skill" class="space-y-4">
        <.dm_input type="text" name="skill[name]" value={@skill.name} required label="Name" />

        <.dm_select
          name="skill[scope]"
          label="Scope"
          options={[{"global", "Global"}]}
          value={@skill.scope || "global"}
        />

        <.dm_textarea
          name="skill[description]"
          value={@skill.description}
          rows={2}
          label="Description"
          resize="none"
        />

        <.dm_textarea
          name="skill[system_prompt_fragment]"
          value={@skill.system_prompt_fragment}
          rows={10}
          label="System Prompt Fragment"
          resize="vertical"
        />

        <div>
          <div class="text-sm font-medium mb-2">Assigned Agents</div>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
            <label
              :for={agent <- @agents}
              class="flex items-start gap-2 rounded border border-outline-variant p-2 text-sm"
            >
              <input
                type="checkbox"
                name="agent_ids[]"
                value={agent.id}
                checked={agent.id in @selected_agent_ids}
              />
              <span>
                <span class="font-medium">{agent.label || agent.name}</span>
                <span class="block text-xs text-on-surface-variant font-mono">{agent.name}</span>
              </span>
            </label>
          </div>
        </div>

        <:actions>
          <.dm_link navigate={~p"/agent/skills"}>
            <.dm_btn type="button" variant="ghost">Cancel</.dm_btn>
          </.dm_link>
          <.dm_btn type="submit" variant="primary">Save Skill</.dm_btn>
        </:actions>
      </.dm_form>
    </.dm_card>
    """
  end

  defp assign_common(socket) do
    assign(socket,
      skills: Skills.list(),
      agents: AgentConfigs.list()
    )
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Skills", skill: nil, selected_agent_ids: [])
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Skill",
      skill: %Skill{scope: "global"},
      selected_agent_ids: []
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Skills.get(id) do
      %Skill{} = skill ->
        assign(socket,
          page_title: "Edit Skill",
          skill: skill,
          selected_agent_ids: AgentSkills.list_agent_ids(skill.id)
        )

      nil ->
        socket
        |> put_flash(:error, "Skill not found")
        |> push_navigate(to: ~p"/agent/skills")
    end
  end
end
