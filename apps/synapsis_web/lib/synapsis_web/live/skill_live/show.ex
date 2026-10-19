defmodule SynapsisWeb.SkillLive.Show do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Skills.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Skill not found")
         |> push_navigate(to: ~p"/settings/skills")}

      skill ->
        remote = (skill.config_overrides || %{})["backplane_source_id"] != nil
        {:ok, assign(socket, skill: skill, page_title: skill.name, remote: remote)}
    end
  end

  @impl true
  def handle_event("update_skill", _params, %{assigns: %{remote: true}} = socket),
    do: {:noreply, put_flash(socket, :error, "Remote skills are managed by their source")}

  def handle_event("update_skill", params, socket) do
    attrs = %{
      name: params["name"],
      description: params["description"],
      system_prompt_fragment: params["system_prompt_fragment"],
      scope: params["scope"]
    }

    case Synapsis.Skills.update(socket.assigns.skill, attrs) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> assign(skill: skill)
         |> reset_react_form("edit-skill-form", skill_form_values(skill))
         |> put_flash(:info, "Skill updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update skill")}
    end
  end

  defp skill_form_values(skill) do
    %{
      "name" => skill.name,
      "scope" => skill.scope,
      "description" => skill.description || "",
      "system_prompt_fragment" => skill.system_prompt_fragment || ""
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_layout current_path="/settings/skills" content_class="max-w-4xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/skills"}>Skills</:crumb>
        <:crumb>{@skill.name}</:crumb>
      </.breadcrumb>

      <.dm_card :if={@remote} variant="bordered">
        <:title>{@skill.name}</:title>
        <p>{@skill.description}</p>
        <dl class="text-sm space-y-2 mt-3">
          <dt>Source</dt><dd>{@skill.config_overrides["backplane_source_id"]}</dd>
          <dt>Skill ID</dt><dd>{@skill.config_overrides["external_id"]}</dd>
          <dt>Revision</dt><dd>
            {get_in(@skill.config_overrides, ["source_metadata", "revision"]) ||
              @skill.config_overrides["external_revision"]}
          </dd>
          <dt>Artifact digest</dt><dd class="break-all">
            {get_in(@skill.config_overrides, ["source_metadata", "artifact_digest"])}
          </dd>
          <dt>Availability</dt><dd>
            {if Synapsis.Skills.runtime_available?(@skill), do: "Available", else: "Unavailable"}
          </dd>
        </dl>
        <p class="text-sm mt-4">The pinned body is fetched when the agent reads this skill.</p>
        <.dm_link navigate={~p"/agent/skills/#{@skill.id}/edit"}>Assign to agents</.dm_link>
      </.dm_card>
      <.dm_card :if={!@remote} variant="bordered">
        <:title>{@skill.name}</:title>

        <.react_form
          for={to_form(%{})}
          as={:skill}
          id="edit-skill-form"
          values={skill_form_values(@skill)}
          draft={react_form_draft(assigns, "edit-skill-form")}
          phx-submit="update_skill"
          class="space-y-4"
        >
          <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 --%>
          <.dm_input
            type="text"
            name="name"
            value={@skill.name}
            required={true}
            label="Name"
          />

          <.dm_react_field name="scope" type="select" options={[%{value: "global", label: "Global"}]} />

          <.dm_textarea
            name="description"
            value={@skill.description}
            rows={2}
            label="Description"
            resize="none"
          />

          <.dm_textarea
            name="system_prompt_fragment"
            value={@skill.system_prompt_fragment}
            rows={10}
            label="System Prompt Fragment"
            resize="vertical"
          />

          <:actions>
            <.dm_btn type="submit" variant="primary">
              Save Changes
            </.dm_btn>
          </:actions>
        </.react_form>
      </.dm_card>
    </.settings_layout>
    """
  end
end
