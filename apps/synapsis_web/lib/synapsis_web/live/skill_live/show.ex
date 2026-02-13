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
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <.link navigate={~p"/settings/skills"} class="hover:text-gray-300">Skills</.link>
          <span>/</span>
          <span class="text-gray-300">{@skill.name}</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">{@skill.name}</h1>

        <.flash_group flash={@flash} />

        <div class="bg-gray-900 rounded-lg p-6 border border-gray-800">
          <form phx-submit="update_skill" class="space-y-4">
            <div>
              <label class="block text-sm text-gray-400 mb-1">Name</label>
              <input
                type="text"
                name="name"
                value={@skill.name}
                required
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">Scope</label>
              <select
                name="scope"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              >
                <option value="global" selected={@skill.scope == "global"}>Global</option>
                <option value="project" selected={@skill.scope == "project"}>Project</option>
              </select>
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">Description</label>
              <textarea
                name="description"
                rows="2"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none resize-none"
              >{@skill.description}</textarea>
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">System Prompt Fragment</label>
              <textarea
                name="system_prompt_fragment"
                rows="10"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none font-mono text-sm resize-y"
              >{@skill.system_prompt_fragment}</textarea>
            </div>

            <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700">
              Save Changes
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
