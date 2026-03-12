defmodule SynapsisWeb.SkillLive.Index do
  use SynapsisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    skills = list_skills()
    {:ok, assign(socket, skills: skills, page_title: "Skills")}
  end

  @impl true
  def handle_event("create_skill", params, socket) do
    attrs = %{
      name: params["name"],
      scope: params["scope"] || "global",
      description: params["description"]
    }

    case Synapsis.Repo.insert(Synapsis.Skill.changeset(%Synapsis.Skill{}, attrs)) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/settings/skills/#{skill.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create skill")}
    end
  end

  def handle_event("delete_skill", %{"id" => id}, socket) do
    case Synapsis.Repo.get(Synapsis.Skill, id) do
      nil -> :ok
      skill -> Synapsis.Repo.delete(skill)
    end

    {:noreply, assign(socket, skills: list_skills())}
  end

  defp list_skills do
    import Ecto.Query
    Synapsis.Repo.all(from(s in Synapsis.Skill, order_by: [asc: s.name]))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Skills</:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Skills</h1>
      </div>

      <.dm_card variant="bordered" class="mb-6">
        <:title>Create Skill</:title>
        <.dm_form for={%{}} phx-submit="create_skill" class="flex gap-2 items-end">
          <div class="flex-1">
            <.dm_input
              type="text"
              name="name"
              value=""
              placeholder="Skill name"
              required={true}
              label="Name"
            />
          </div>
          <div>
            <.dm_select
              name="scope"
              options={[{"global", "Global"}, {"project", "Project"}]}
              value="global"
            />
          </div>
          <.dm_btn type="submit" variant="primary">
            Create
          </.dm_btn>
        </.dm_form>
      </.dm_card>

      <div class="space-y-2">
        <.dm_card :for={skill <- @skills} variant="bordered">
          <div class="flex justify-between items-center">
            <.dm_link navigate={~p"/settings/skills/#{skill.id}"} class="flex-1">
              <div class="font-medium">{skill.name}</div>
              <div class="flex gap-2 mt-1">
                <.dm_badge
                  color={if skill.scope == "global", do: "primary", else: "secondary"}
                  size="sm"
                >
                  {skill.scope}
                </.dm_badge>
                <.dm_badge :if={skill.is_builtin} color="warning" size="sm">
                  built-in
                </.dm_badge>
              </div>
            </.dm_link>
            <.dm_btn
              :if={!skill.is_builtin}
              variant="ghost"
              size="sm"
              phx-click="delete_skill"
              phx-value-id={skill.id}
              confirm="Delete this skill?"
            >
              Delete
            </.dm_btn>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end
end
