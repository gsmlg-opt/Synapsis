defmodule SynapsisWeb.SkillLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  @impl true
  def mount(_params, _session, socket) do
    skills = list_skills()

    {:ok,
     assign(socket,
       skills: skills,
       page_title: "Skills",
       sources: Synapsis.Backplane.Connection.list(),
       source_providers: Synapsis.Backplane.ProviderSource.available(),
       syncing_source: nil
     )}
  end

  @impl true
  def handle_event("select_source", %{"provider_id" => id}, socket) do
    case Synapsis.Backplane.select_provider(id, "skills") do
      {:ok, _source} ->
        {:noreply,
         socket
         |> assign(sources: Synapsis.Backplane.Connection.list())
         |> put_flash(:info, "Remote skill source added. Refresh to discover skills.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Provider connection is unavailable")}
    end
  end

  def handle_event("refresh_source", %{"id" => id}, %{assigns: %{syncing_source: nil}} = socket) do
    {:noreply,
     socket
     |> assign(syncing_source: id)
     |> start_async(:skill_source, fn -> Synapsis.Backplane.refresh(id) end)}
  end

  def handle_event("refresh_source", _params, socket), do: {:noreply, socket}

  def handle_event("create_skill", params, socket) do
    attrs = %{
      name: params["name"],
      scope: params["scope"] || "global",
      description: params["description"]
    }

    case Synapsis.Skills.create(attrs) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/settings/skills/#{skill.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create skill")}
    end
  end

  def handle_event("delete_skill", %{"id" => id}, socket) do
    case Synapsis.Skills.get(id) do
      nil ->
        {:noreply, socket}

      skill ->
        case Synapsis.Skills.delete(skill) do
          {:ok, _} -> {:noreply, assign(socket, skills: list_skills())}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to delete skill")}
        end
    end
  end

  @impl true
  def handle_async(:skill_source, result, socket) do
    socket =
      assign(socket,
        syncing_source: nil,
        sources: Synapsis.Backplane.Connection.list(),
        skills: list_skills()
      )

    case result do
      {:ok, {:ok, %{status: "ready"}}} ->
        {:noreply, put_flash(socket, :info, "Remote skills refreshed")}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Remote skill discovery failed. Check source status.")}
    end
  end

  defp source_label(skill, sources) do
    case (skill.config_overrides || %{})["backplane_source_id"] do
      nil ->
        "Local"

      id ->
        case Enum.find(sources, &(&1.id == id)) do
          nil -> "Unavailable source " <> id
          source -> source.name
        end
    end
  end

  defp list_skills, do: Synapsis.Skills.list()

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_layout current_path="/settings/skills" content_class="max-w-4xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Skills</:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Skills</h1>
      </div>

      <.dm_card variant="bordered" class="mb-6">
        <:title>Remote skill sources</:title>
        <.react_form
          for={%{}}
          id="skill-source-form"
          values={%{"provider_id" => ""}}
          phx-submit="select_source"
          class="space-y-3"
        >
          <.dm_react_field
            type="select"
            name="provider_id"
            label="Backplane provider"
            options={[
              %{value: "", label: "Select provider"}
              | Enum.map(@source_providers, &%{value: &1.id, label: &1.name})
            ]}
          />
          <.dm_btn type="submit" variant="primary" size="sm">Add remote source</.dm_btn>
        </.react_form>
        <div :for={source <- @sources} class="flex items-center gap-3 mt-3" data-source-id={source.id}>
          <span>{source.name}</span><.dm_badge size="sm">{source.status}</.dm_badge>
          <span :if={!source.enabled} class="text-error text-sm">Disabled</span>
          <span
            :if={
              source.provider_id &&
                !match?({:ok, _}, Synapsis.Backplane.ProviderSource.get(source.provider_id))
            }
            class="text-error text-sm"
          >Provider unavailable</span>
          <span :if={source.last_error} role="alert" class="text-error text-sm">{source.last_error}</span>
          <.dm_btn
            size="sm"
            phx-click="refresh_source"
            phx-value-id={source.id}
            disabled={!is_nil(@syncing_source) || !source.enabled}
          >
            {if @syncing_source == source.id, do: "Refreshing…", else: "Refresh skills"}
          </.dm_btn>
        </div>
      </.dm_card>

      <.dm_card variant="bordered" class="mb-6">
        <:title>Create Skill</:title>
        <.react_form
          for={%{}}
          id="create-skill-form"
          values={%{"name" => "", "scope" => "global"}}
          draft={react_form_draft(assigns, "create-skill-form")}
          phx-submit="create_skill"
          class="flex gap-2 items-end"
        >
          <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 --%>
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
            <.dm_react_field
              name="scope"
              type="select"
              options={[%{value: "global", label: "Global"}]}
            />
          </div>
          <.dm_btn type="submit" variant="primary">
            Create
          </.dm_btn>
        </.react_form>
      </.dm_card>

      <div class="space-y-4">
        <div
          :for={{source, skills} <- Enum.group_by(@skills, &source_label(&1, @sources))}
          class="space-y-2"
        >
          <h2 class="font-semibold">{source}</h2>
          <.dm_card :for={skill <- skills} variant="bordered">
            <div class="flex justify-between items-center">
              <.dm_link navigate={~p"/settings/skills/#{skill.id}"} class="flex-1">
                <div class="font-medium">{skill.name}</div>
                <div class="text-xs text-on-surface-variant">{source_label(skill, @sources)}</div>
                <div class="flex gap-2 mt-1">
                  <.dm_badge
                    variant={if skill.scope == "global", do: "primary", else: "secondary"}
                    size="sm"
                  >
                    {skill.scope}
                  </.dm_badge>
                  <.dm_badge :if={skill.is_builtin} variant="warning" size="sm">
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
    </.settings_layout>
    """
  end
end
