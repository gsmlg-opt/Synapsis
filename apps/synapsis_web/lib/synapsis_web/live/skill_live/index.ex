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
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <span class="text-gray-300">Skills</span>
        </div>

        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">Skills</h1>
        </div>

        <.flash_group flash={@flash} />

        <div class="mb-6 bg-gray-900 rounded-lg p-4 border border-gray-800">
          <form phx-submit="create_skill" class="flex gap-2">
            <input
              type="text"
              name="name"
              placeholder="Skill name"
              required
              class="flex-1 bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            />
            <select
              name="scope"
              class="bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
            >
              <option value="global">Global</option>
              <option value="project">Project</option>
            </select>
            <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              Create
            </button>
          </form>
        </div>

        <div class="space-y-2">
          <div
            :for={skill <- @skills}
            class="bg-gray-900 rounded-lg p-4 border border-gray-800 flex justify-between items-center"
          >
            <.link navigate={~p"/settings/skills/#{skill.id}"} class="flex-1">
              <div class="font-medium">{skill.name}</div>
              <div class="text-xs text-gray-500 mt-1">
                {skill.scope}
                <span :if={skill.is_builtin} class="text-yellow-500"> · built-in</span>
              </div>
            </.link>
            <button
              :if={!skill.is_builtin}
              phx-click="delete_skill"
              phx-value-id={skill.id}
              data-confirm="Delete this skill?"
              class="text-gray-600 hover:text-red-400 text-sm"
            >
              Delete
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
