defmodule SynapsisWeb.SkillLive.Show do
  use SynapsisWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Repo.get(Synapsis.Skill, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Skill not found")
         |> push_navigate(to: ~p"/settings/skills")}

      skill ->
        {:ok, assign(socket, skill: skill, page_title: skill.name)}
    end
  end

  @impl true
  def handle_event("update_skill", params, socket) do
    attrs = %{
      name: params["name"],
      description: params["description"],
      system_prompt_fragment: params["system_prompt_fragment"],
      scope: params["scope"]
    }

    changeset = Synapsis.Skill.changeset(socket.assigns.skill, attrs)

    case Synapsis.Repo.update(changeset) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> assign(skill: skill)
         |> put_flash(:info, "Skill updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update skill")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/skills"}>Skills</:crumb>
        <:crumb>{@skill.name}</:crumb>
      </.breadcrumb>

      <.dm_card variant="bordered">
        <:title>{@skill.name}</:title>

        <.dm_form for={to_form(%{})} as={:skill} phx-submit="update_skill" class="space-y-4">
          <.dm_input
            type="text"
            name="name"
            value={@skill.name}
            required={true}
            label="Name"
          />

          <.dm_select
            name="scope"
            options={[{"global", "Global"}, {"project", "Project"}]}
            value={@skill.scope}
          />

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
        </.dm_form>
      </.dm_card>
    </div>
    """
  end
end
