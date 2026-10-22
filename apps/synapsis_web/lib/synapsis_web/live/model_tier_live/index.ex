defmodule SynapsisWeb.ModelTierLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  alias Synapsis.{Models, Providers}

  @context_presets [
    {"256000", "256k"},
    {"384000", "384k"},
    {"500000", "500k"},
    {"768000", "768k"},
    {"1000000", "1M"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Providers.subscribe()

    migration = Providers.migrate_model_catalog()
    {:ok, providers} = Providers.list()

    provider_id =
      case providers do
        [first | _] -> first.id
        [] -> ""
      end

    socket =
      socket
      |> assign(
        page_title: "Models",
        providers: providers,
        provider_id: provider_id,
        show_model_form: false,
        editing_id: nil,
        model_values: new_values(provider_id),
        model_errors: [],
        discovering: false,
        selected_ids: MapSet.new()
      )
      |> reload_catalog()
      |> load_suggestions()

    socket =
      if migration == :ok,
        do: socket,
        else: put_flash(socket, :error, "Failed to migrate existing models")

    {:ok, socket}
  end

  @impl true
  def handle_event("select_provider", params, socket) do
    id = params["provider_id"] || ""
    {:noreply, socket |> assign(provider_id: id) |> load_suggestions()}
  end

  def handle_event("change_model_form", _params, socket), do: {:noreply, socket}

  def handle_event("new_model", _params, socket) do
    {:noreply, socket |> reset_editor() |> assign(show_model_form: true)}
  end

  def handle_event("save_model", params, socket) do
    attrs = Map.put(params, "enabled", params["enabled"] in [true, "true", "on"])
    provider_id = params["provider_id"]

    result =
      with {:ok, _} <- Providers.get(provider_id) do
        if socket.assigns.editing_id,
          do: Models.update(socket.assigns.editing_id, attrs),
          else: Models.create(attrs)
      end

    case result do
      {:ok, _} ->
        Providers.notify_changed()

        {:noreply,
         socket |> reset_editor() |> reload_catalog() |> put_flash(:info, "Model saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
            Enum.reduce(options, message, fn {key, value}, text ->
              String.replace(text, "%{#{key}}", to_string(value))
            end)
          end)
          |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)

        {:noreply, assign(socket, model_values: attrs, model_errors: errors)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save model; select an existing provider")}
    end
  end

  def handle_event("edit_model", %{"id" => id}, socket) do
    case Models.get(id) do
      {:ok, model} ->
        values =
          Map.from_struct(model)
          |> Map.take([:provider_id, :model, :name, :context_window, :enabled])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:noreply,
         socket
         |> assign(show_model_form: true, editing_id: id, model_values: values, model_errors: [])
         |> reset_react_form("model-form", values)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Model no longer exists")}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, reset_editor(socket)}

  def handle_event("toggle_model", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    selected =
      cond do
        not Enum.any?(socket.assigns.models, &(&1.id == id)) -> selected
        MapSet.member?(selected, id) -> MapSet.delete(selected, id)
        true -> MapSet.put(selected, id)
      end

    {:noreply, assign(socket, selected_ids: selected)}
  end

  def handle_event("toggle_all_models", _params, socket) do
    ids = MapSet.new(socket.assigns.models, & &1.id)
    selected = if ids == socket.assigns.selected_ids, do: MapSet.new(), else: ids
    {:noreply, assign(socket, selected_ids: selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new())}
  end

  def handle_event("bulk_context", %{"context_window" => context}, socket) do
    if Enum.any?(@context_presets, fn {value, _} -> value == context end) do
      {:noreply,
       bulk_operation(socket, &Models.update(&1, %{context_window: context}), "Updated")}
    else
      {:noreply, put_flash(socket, :error, "Select a context window preset")}
    end
  end

  def handle_event("bulk_status", %{"enabled" => enabled}, socket)
      when enabled in ["true", "false"] do
    {:noreply,
     bulk_operation(socket, &Models.update(&1, %{enabled: enabled == "true"}), "Updated")}
  end

  def handle_event("bulk_delete", _params, socket) do
    {:noreply, bulk_operation(socket, &Models.delete/1, "Deleted")}
  end

  def handle_event("delete_model", %{"id" => id}, socket) do
    case Models.delete(id) do
      {:ok, _} ->
        Providers.notify_changed()

        {:noreply,
         socket |> reset_editor() |> reload_catalog() |> put_flash(:info, "Model deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete model")}
    end
  end

  def handle_event("import_model", %{"model" => model}, socket) do
    suggestion = Enum.find(socket.assigns.suggestions, &(&1.id == model))

    with true <- not is_nil(suggestion),
         {:ok, _} <- Providers.get(socket.assigns.provider_id),
         {:ok, _} <- Models.import(socket.assigns.provider_id, [suggestion]) do
      Providers.notify_changed()

      {:noreply, socket |> reload_catalog() |> put_flash(:info, "Model imported")}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to import model; enter it manually with a valid context window"
         )}
    end
  end

  def handle_event("import_all_models", _params, socket) do
    with {:ok, _} <- Providers.get(socket.assigns.provider_id),
         {:ok, _} <- Models.import(socket.assigns.provider_id, socket.assigns.suggestions) do
      Providers.notify_changed()

      {:noreply, socket |> reload_catalog() |> put_flash(:info, "Model suggestions imported")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to import model suggestions")}
    end
  end

  def handle_event("refresh_models", _params, socket) do
    id = socket.assigns.provider_id

    if socket.assigns.discovering or id == "" do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(discovering: true)
       |> start_async(:discover_models, fn -> Providers.refresh_models(id) end)}
    end
  end

  @impl true
  def handle_async(:discover_models, {:ok, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> assign(discovering: false)
     |> load_suggestions()
     |> put_flash(:info, "Model suggestions refreshed")}
  end

  def handle_async(:discover_models, {:ok, {:error, "HTTP 401"}}, socket) do
    {:noreply,
     socket
     |> assign(discovering: false)
     |> put_flash(
       :error,
       "Failed to discover models (HTTP 401). Check the access token in provider settings; existing models are unchanged"
     )}
  end

  def handle_async(:discover_models, {:ok, {:error, "HTTP 403"}}, socket) do
    {:noreply,
     socket
     |> assign(discovering: false)
     |> put_flash(
       :error,
       "Failed to discover models (HTTP 403). Check the provider access permissions; existing models are unchanged"
     )}
  end

  def handle_async(:discover_models, _error, socket) do
    {:noreply,
     socket
     |> assign(discovering: false)
     |> put_flash(:error, "Failed to discover models; existing models are unchanged")}
  end

  @impl true
  def handle_info({:provider_catalog_changed}, socket) do
    socket = socket |> reload_catalog() |> load_suggestions()

    socket =
      if socket.assigns.editing_id &&
           not Enum.any?(socket.assigns.models, &(&1.id == socket.assigns.editing_id)) do
        socket |> reset_editor() |> put_flash(:error, "The model being edited was deleted")
      else
        socket
      end

    values = react_form_draft(socket.assigns, "model-form") || socket.assigns.model_values

    socket =
      if socket.assigns.show_model_form and is_nil(socket.assigns.editing_id) and
           values["provider_id"] not in [nil, ""] and
           not Enum.any?(socket.assigns.providers, &(&1.id == values["provider_id"])) do
        values = Map.put(values, "provider_id", "")

        socket
        |> assign(
          model_values: values,
          model_errors: ["The selected provider was deleted. Select a provider before saving."]
        )
        |> reset_react_form("model-form", values)
      else
        socket
      end

    {:noreply, socket}
  end

  defp reload_catalog(socket) do
    {:ok, providers} = Providers.list()

    previous_id = socket.assigns.provider_id

    provider_id =
      if Enum.any?(providers, &(&1.id == previous_id)),
        do: previous_id,
        else: Enum.find_value(providers, "", & &1.id)

    socket = assign(socket, providers: providers, provider_id: provider_id)

    socket =
      if provider_id == previous_id do
        socket
      else
        reset_react_form(socket, "model-discovery-provider-form", %{"provider_id" => provider_id})
      end

    {:ok, models} = Models.list()
    available = MapSet.new(Providers.configured_models(), & &1.id)
    names = Map.new(socket.assigns.providers, &{&1.id, &1.name})

    assign(socket,
      selected_ids: MapSet.intersection(socket.assigns.selected_ids, MapSet.new(models, & &1.id)),
      models:
        Enum.map(
          models,
          &Map.merge(Map.from_struct(&1), %{
            provider: Map.get(names, &1.provider_id, "Provider deleted"),
            available: MapSet.member?(available, &1.id)
          })
        )
    )
  end

  defp bulk_operation(socket, operation, verb) do
    if MapSet.size(socket.assigns.selected_ids) == 0 do
      put_flash(socket, :error, "Select at least one model")
    else
      results = Enum.map(socket.assigns.selected_ids, operation)
      succeeded = Enum.count(results, &match?({:ok, _}, &1))
      failed = length(results) - succeeded
      if succeeded > 0, do: Providers.notify_changed()
      socket = reload_catalog(socket)

      if failed == 0,
        do: put_flash(socket, :info, "#{verb} #{succeeded} models"),
        else: put_flash(socket, :error, "#{verb} #{succeeded} models; #{failed} failed")
    end
  end

  defp load_suggestions(socket) do
    suggestions =
      case Providers.get(socket.assigns.provider_id) do
        {:ok, provider} ->
          Providers.model_suggestions(provider)

        {:error, _} ->
          []
      end

    assign(socket, suggestions: suggestions)
  end

  defp reset_editor(socket) do
    values = new_values(socket.assigns.provider_id)

    socket
    |> assign(show_model_form: false, editing_id: nil, model_values: values, model_errors: [])
    |> reset_react_form("model-form", values)
  end

  defp new_values(provider_id),
    do: %{
      "provider_id" => provider_id,
      "model" => "",
      "name" => "",
      "context_window" => %Synapsis.ModelConfig{}.context_window,
      "enabled" => true
    }

  defp context_options(value) do
    value = to_string(value)

    if value == "" or List.keymember?(@context_presets, value, 0),
      do: @context_presets,
      else: @context_presets ++ [{value, "#{value} tokens (custom)"}]
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        context_presets: @context_presets,
        context_options: context_options(assigns.model_values["context_window"]),
        selected_count: MapSet.size(assigns.selected_ids),
        provider_options:
          Enum.map(
            assigns.providers,
            &%{value: &1.id, label: if(&1.enabled, do: &1.name, else: "#{&1.name} (disabled)")}
          )
      )

    ~H"""
    <.settings_layout current_path="/settings/models" content_class="max-w-5xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Models</:crumb>
      </.breadcrumb>
      <div class="flex items-center justify-between gap-3 mb-4">
        <h1 class="text-2xl font-bold">Models</h1>
        <.dm_btn variant="primary" size="sm" phx-click="new_model" disabled={@providers == []}>
          Add Model
        </.dm_btn>
      </div>
      <p class="text-sm text-on-surface-variant mb-6">
        Configure models and their context windows in tokens. Agents and sessions can select enabled models from available providers.
      </p>
      <p :if={@providers == []} class="mb-6">
        Add a <.link navigate={~p"/settings/providers/new"} class="link">provider connection</.link>
        first.
      </p>
      <.dm_modal
        :if={@show_model_form}
        id="model-modal"
        size="lg"
        class="synapsis-model-modal"
        phx-hook="MCPFormModal"
        data-close-event="cancel_edit"
      >
        <:title>{if @editing_id, do: "Edit Model", else: "Add Model"}</:title>
        <:body>
          <.react_form
            for={to_form(%{})}
            id="model-form"
            values={@model_values}
            draft={react_form_draft(assigns, "model-form")}
            structure={[@editing_id, @provider_options, @context_options]}
            phx-change="change_model_form"
            phx-submit="save_model"
            class="space-y-4"
          >
            <.dm_react_field
              name="provider_id"
              type="select"
              label="Provider"
              options={@provider_options}
            />
            <.dm_input
              id="model-id"
              autofocus
              name="model"
              label="Model ID"
              value={@model_values["model"]}
              required
              placeholder="Model ID sent to the provider"
            />
            <.dm_input name="name" label="Display Name (optional)" value={@model_values["name"]} />
            <.dm_select
              id="model-context-window"
              name="context_window"
              label="Context Window (tokens)"
              value={to_string(@model_values["context_window"])}
              options={@context_options}
            />
            <.dm_react_field name="enabled" type="checkbox" label="Enabled" />
            <:actions>
              <%!-- # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#88 --%>
              <.dm_btn native_submit variant="primary">Save Model</.dm_btn>
              <.dm_btn type="button" variant="ghost" phx-click="cancel_edit">Cancel</.dm_btn>
            </:actions>
          </.react_form>
          <p :for={error <- @model_errors} role="alert" class="text-error text-sm mt-2">{error}</p>
        </:body>
      </.dm_modal>
      <.dm_card variant="bordered" class="mb-6">
        <:title>Configured Models</:title>
        <p :if={@models == []} class="text-on-surface-variant text-sm">No configured models.</p>
        <div :if={@models != []} class="flex flex-wrap items-center gap-3 mb-4">
          <.dm_checkbox
            name="all_models"
            label="Select all"
            hidden_input={false}
            checked={@selected_count == length(@models)}
            indeterminate={@selected_count > 0 and @selected_count < length(@models)}
            phx-click="toggle_all_models"
          />
          <span id="model-selection-count" class="text-sm" aria-live="polite">{@selected_count} selected</span>
          <.dm_btn :if={@selected_count > 0} variant="ghost" size="xs" phx-click="clear_selection">
            Clear selection
          </.dm_btn>
        </div>
        <div :if={@selected_count > 0} class="flex flex-wrap items-end gap-3 mb-4">
          <.react_form
            for={%{}}
            id="bulk-context-form"
            values={%{"context_window" => "256000"}}
            draft={react_form_draft(assigns, "bulk-context-form")}
            phx-submit="bulk_context"
          >
            <div class="flex flex-wrap items-end gap-2">
              <.dm_select
                id="bulk-context-window"
                name="context_window"
                label="Context Window (tokens)"
                value="256000"
                options={@context_presets}
              />
              <%!-- # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#88 --%>
              <.dm_btn native_submit variant="secondary" size="sm">Apply to selected</.dm_btn>
            </div>
          </.react_form>
          <.dm_btn variant="ghost" size="sm" phx-click="bulk_status" phx-value-enabled="true">
            Enable selected
          </.dm_btn>
          <.dm_btn variant="ghost" size="sm" phx-click="bulk_status" phx-value-enabled="false">
            Disable selected
          </.dm_btn>
          <.dm_btn
            variant="error"
            size="sm"
            phx-click="bulk_delete"
            confirm={"Delete #{@selected_count} selected models?"}
          >
            Delete selected
          </.dm_btn>
        </div>
        <div class="overflow-x-auto">
          <.dm_table :if={@models != []} data={@models}>
            <:col :let={model} label="Select">
              <.dm_checkbox
                name="model_selection"
                hidden_input={false}
                checked={MapSet.member?(@selected_ids, model.id)}
                aria-label={"Select #{model.model} from #{model.provider}"}
                phx-click="toggle_model"
                phx-value-id={model.id}
              />
            </:col>
            <:col :let={model} label="Provider">{model.provider}</:col>
            <:col :let={model} label="Model">
              <div>{model.name || model.model}</div><code class="text-xs">{model.model}</code>
            </:col>
            <:col :let={model} label="Context (tokens)">{model.context_window}</:col>
            <:col :let={model} label="Status">
              {cond do
                not model.enabled -> "Disabled"
                model.available -> "Available"
                true -> "Provider or source unavailable"
              end}
            </:col>
            <:col :let={model} label="Actions">
              <.dm_btn variant="ghost" size="xs" phx-click="edit_model" phx-value-id={model.id}>
                Edit
              </.dm_btn>
              <.dm_btn
                variant="error"
                size="xs"
                phx-click="delete_model"
                phx-value-id={model.id}
                confirm="Delete this configured model?"
              >
                Delete
              </.dm_btn>
            </:col>
          </.dm_table>
        </div>
      </.dm_card>
      <.dm_card :if={@providers != []} variant="bordered">
        <:title>Import Model Suggestions</:title>
        <.react_form
          for={to_form(%{})}
          id="model-discovery-provider-form"
          values={%{"provider_id" => @provider_id}}
          draft={react_form_draft(assigns, "model-discovery-provider-form")}
          structure={@provider_options}
          phx-change="select_provider"
          class="mb-4"
        >
          <.dm_react_field
            name="provider_id"
            type="select"
            label="Provider"
            options={@provider_options}
          />
        </.react_form>
        <div class="flex flex-wrap gap-2">
          <.dm_btn
            variant="secondary"
            size="sm"
            phx-click="refresh_models"
            disabled={@discovering or @provider_id == ""}
          >
            {if @discovering, do: "Discovering…", else: "Discover Models"}
          </.dm_btn>
          <.dm_btn
            variant="ghost"
            size="sm"
            phx-click="import_all_models"
            disabled={@suggestions == []}
          >
            Import All
          </.dm_btn>
          <.link
            :if={@provider_id != ""}
            navigate={~p"/settings/providers/#{@provider_id}"}
            class="link text-sm self-center"
          >
            Edit provider connection
          </.link>
        </div>
        <p class="text-xs text-on-surface-variant my-3">
          Discovery supplies suggestions. Importing again preserves your edits and disabled models.
        </p>
        <p :if={@suggestions == []} class="text-sm text-on-surface-variant">
          No model suggestions. Discover models from this provider or add a model manually.
        </p>
        <div
          :for={model <- @suggestions}
          class="flex justify-between items-center gap-3 py-2 border-b border-outline/20"
        >
          <div>
            <span>{model.name || model.id}</span><code class="block text-xs text-on-surface-variant">{model.id} · {model.context_window} tokens</code>
          </div>
          <.dm_btn variant="ghost" size="xs" phx-click="import_model" phx-value-model={model.id}>
            Import
          </.dm_btn>
        </div>
      </.dm_card>
    </.settings_layout>
    """
  end
end
