defmodule SynapsisWeb.SkillLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Synapsis.Providers.subscribe()

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
  def handle_event("change_source_form", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_source", %{"provider_id" => id}, socket) do
    case Synapsis.Backplane.select_provider(id, "skills") do
      {:ok, _source} ->
        {:noreply,
         socket
         |> assign(sources: Synapsis.Backplane.Connection.list())
         |> put_flash(:info, "Remote skill source added. Refresh to discover skills.")}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, provider_issue(id) || "Provider connection is unavailable")}
    end
  end

  def handle_event("refresh_source", %{"id" => id}, %{assigns: %{syncing_source: nil}} = socket) do
    with {:ok, source} <- Synapsis.Backplane.Connection.get(id),
         true <- Synapsis.Backplane.Connection.surface_enabled?(source, "skills") do
      {:noreply,
       socket
       |> assign(syncing_source: id)
       |> start_async(:skill_source, fn -> Synapsis.Backplane.refresh(id) end)}
    else
      false -> {:noreply, put_flash(socket, :error, skills_not_enabled_message())}
      _ -> {:noreply, put_flash(socket, :error, "Remote skill source is unavailable")}
    end
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
    source_id = socket.assigns.syncing_source

    socket =
      assign(socket,
        syncing_source: nil,
        sources: Synapsis.Backplane.Connection.list(),
        source_providers: Synapsis.Backplane.ProviderSource.available(),
        skills: list_skills()
      )

    case result do
      {:ok, {:ok, %{status: "ready"}}} ->
        {:noreply, put_flash(socket, :info, "Remote skills refreshed")}

      {:ok, {:error, :provider_unavailable}} ->
        source = Enum.find(socket.assigns.sources, &(&1.id == source_id))

        reason =
          (source && provider_issue(source.provider_id)) || "Provider connection is unavailable"

        {:noreply, put_flash(socket, :error, "Remote skill discovery failed. #{reason}")}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Remote skill discovery failed. Check source status.")}
    end
  end

  @impl true
  def handle_info({:provider_catalog_changed}, socket) do
    {:noreply,
     assign(socket,
       sources: Synapsis.Backplane.Connection.list(),
       source_providers: Synapsis.Backplane.ProviderSource.available(),
       skills: list_skills()
     )}
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

  defp provider_issue(nil), do: nil

  defp provider_issue(id) do
    case Synapsis.Providers.get(id) do
      {:ok, provider} ->
        cond do
          !provider.enabled ->
            "Provider #{provider.name} is disabled. Enable it in Providers."

          !Synapsis.Providers.credential_available?(provider) ->
            "Provider #{provider.name} credential is unavailable. Update it in Providers."

          is_nil(provider.base_url) || String.trim(provider.base_url) == "" ->
            "Provider #{provider.name} has no endpoint. Set its base URL in Providers."

          true ->
            nil
        end

      {:error, :not_found} ->
        "Provider #{id} no longer exists. Choose a provider and click Add remote source."
    end
  end

  defp skills_not_enabled_message do
    "Skills not enabled. Choose this provider and click Add remote source to enable skill discovery."
  end

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
          draft={react_form_draft(assigns, "skill-source-form")}
          structure={Enum.map(@source_providers, &{&1.id, &1.name, &1.enabled})}
          phx-change="change_source_form"
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
        <div
          :for={source <- @sources}
          class="flex flex-wrap items-center gap-3 mt-3 min-w-0"
          data-source-id={source.id}
        >
          <% provider_issue = provider_issue(source.provider_id) %>
          <% skills_enabled = Synapsis.Backplane.Connection.surface_enabled?(source, "skills") %>
          <span class="break-all">{source.name}</span><.dm_badge size="sm">{source.status}</.dm_badge>
          <span :if={!source.enabled} class="text-error text-sm">Disabled</span>
          <span :if={provider_issue} class="min-w-0 break-words text-error text-sm">{provider_issue}</span>
          <.dm_link :if={provider_issue} navigate={~p"/settings/providers"}>Manage providers</.dm_link>
          <span :if={!skills_enabled && !provider_issue} class="min-w-0 break-words text-sm">{skills_not_enabled_message()}</span>
          <span :if={source.last_error} role="alert" class="min-w-0 break-words text-error text-sm">{source.last_error}</span>
          <.dm_btn
            size="sm"
            phx-click="refresh_source"
            phx-value-id={source.id}
            disabled={!is_nil(@syncing_source) || !source.enabled || !skills_enabled}
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
