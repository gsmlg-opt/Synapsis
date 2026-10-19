defmodule SynapsisWeb.ModelTierLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  alias Synapsis.{Models, Providers}

  @impl true
  def mount(_params, _session, socket) do
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
        editing_id: nil,
        model_values: new_values(provider_id),
        model_errors: [],
        discovering: false
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
  def handle_event("select_provider", %{"provider_id" => id}, socket) do
    {:noreply, socket |> assign(provider_id: id) |> load_suggestions()}
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

        {:noreply, assign(socket, model_errors: errors)}

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
         |> assign(editing_id: id, model_values: values, model_errors: [])
         |> reset_react_form("model-form", values)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Model no longer exists")}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, reset_editor(socket)}

  def handle_event("delete_model", %{"id" => id}, socket) do
    case Models.delete(id) do
      {:ok, _} ->
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

  def handle_async(:discover_models, _error, socket) do
    {:noreply,
     socket
     |> assign(discovering: false)
     |> put_flash(:error, "Failed to discover models; existing models are unchanged")}
  end

  defp reload_catalog(socket) do
    {:ok, models} = Models.list()
    available = MapSet.new(Providers.configured_models(), & &1.id)
    names = Map.new(socket.assigns.providers, &{&1.id, &1.name})

    assign(socket,
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
    |> assign(editing_id: nil, model_values: values, model_errors: [])
    |> reset_react_form("model-form", values)
  end

  defp new_values(provider_id),
    do: %{
      "provider_id" => provider_id,
      "model" => "",
      "name" => "",
      "context_window" => "",
      "enabled" => true
    }

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
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
      <h1 class="text-2xl font-bold mb-4">Models</h1>
      <p class="text-sm text-on-surface-variant mb-6">
        Configure models and their context windows in tokens. Agents and sessions can select enabled models from available providers.
      </p>
      <.dm_card variant="bordered" class="mb-6">
        <:title>{if @editing_id, do: "Edit Model", else: "Add Model"}</:title>
        <p :if={@providers == []}>
          Add a <.link navigate={~p"/settings/providers/new"} class="link">provider connection</.link>
          first.
        </p>
        <.react_form
          :if={@providers != []}
          for={to_form(%{})}
          id="model-form"
          values={@model_values}
          draft={react_form_draft(assigns, "model-form")}
          structure={[@editing_id, @provider_options]}
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
            name="model"
            label="Model ID"
            value={@model_values["model"]}
            required
            placeholder="Model ID sent to the provider"
          />
          <.dm_input name="name" label="Display Name (optional)" value={@model_values["name"]} />
          <.dm_input
            type="number"
            name="context_window"
            label="Context Window (tokens)"
            value={@model_values["context_window"]}
            min="1"
            step="1"
            required
          />
          <.dm_react_field name="enabled" type="checkbox" label="Enabled" />
          <:actions>
            <.dm_btn type="submit" variant="primary">Save Model</.dm_btn>
            <.dm_btn :if={@editing_id} type="button" variant="ghost" phx-click="cancel_edit">
              Cancel
            </.dm_btn>
          </:actions>
        </.react_form>
        <p :for={error <- @model_errors} role="alert" class="text-error text-sm mt-2">{error}</p>
      </.dm_card>
      <.dm_card variant="bordered" class="mb-6">
        <:title>Configured Models</:title>
        <p :if={@models == []} class="text-on-surface-variant text-sm">No configured models.</p>
        <.dm_table :if={@models != []} data={@models}>
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
        <.dm_btn variant="secondary" size="sm" phx-click="refresh_models" disabled={@discovering}>
          {if @discovering, do: "Discovering…", else: "Discover Models"}
        </.dm_btn>
        <p class="text-xs text-on-surface-variant my-3">
          Discovery supplies suggestions. Importing again preserves your edits and disabled models.
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
