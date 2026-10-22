defmodule SynapsisWeb.ProviderLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  @custom_presets [
    %{name: "", type: "openai", base_url: "", label: "OpenAI Compatible", custom: true},
    %{name: "", type: "anthropic", base_url: "", label: "Anthropic Compatible", custom: true}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Synapsis.Providers.subscribe()

    {:ok, credentials} = Synapsis.Credentials.list()
    {:ok, assign(socket, providers: [], credentials: credentials, page_title: "Providers")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:ok, providers} = Synapsis.Providers.list()

    {:noreply,
     apply_action(socket, socket.assigns.live_action, params) |> assign(providers: providers)}
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, show_form: true, selected_preset: nil)
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_form: false, selected_preset: nil)
  end

  @impl true
  def handle_event("select_preset", %{"name" => name}, socket) do
    preset =
      Synapsis.Providers.preset_providers()
      |> Enum.find(&(&1.name == name))

    {:noreply,
     socket
     |> reset_react_form("create-provider-form")
     |> assign(selected_preset: Map.put(preset, :custom, false))}
  end

  def handle_event("select_custom", %{"type" => type}, socket) do
    preset = Enum.find(@custom_presets, &(&1.type == type))

    {:noreply,
     socket |> reset_react_form("create-provider-form") |> assign(selected_preset: preset)}
  end

  def handle_event("back_to_presets", _params, socket) do
    {:noreply, socket |> reset_react_form("create-provider-form") |> assign(selected_preset: nil)}
  end

  def handle_event("change_provider_form", _params, socket), do: {:noreply, socket}

  def handle_event("create_provider", params, socket) do
    preset = socket.assigns.selected_preset

    attrs = %{
      name: params["name"],
      type: preset.type,
      preset: if(preset.custom, do: nil, else: preset.name),
      config: %{"model_catalog_migrated" => true},
      base_url:
        if(preset.custom or Map.get(preset, :base_url_editable, false),
          do: params["base_url"],
          else: preset.base_url
        ),
      credential_id:
        if(preset.name == "openai-sub", do: nil, else: blank_to_nil(params["credential_id"]))
    }

    case Synapsis.Providers.create(attrs) do
      {:ok, provider} ->
        {provider, refresh_flash} = maybe_refresh_models_on_create(provider, preset)
        {:ok, providers} = Synapsis.Providers.list()

        # Redirect OAuth providers to show page for OAuth login
        redirect_to =
          if preset.name == "openai-sub" do
            ~p"/settings/providers/#{provider.id}"
          else
            ~p"/settings/providers"
          end

        {:noreply,
         socket
         |> assign(providers: providers, show_form: false, selected_preset: nil)
         |> put_flash(:info, refresh_flash)
         |> push_navigate(to: redirect_to)}

      {:error, %Ecto.Changeset{errors: errors}} ->
        msg =
          case Keyword.get(errors, :name) do
            {"has already been taken", _} -> "Name already taken"
            _ -> "Failed to create provider"
          end

        {:noreply, put_flash(socket, :error, msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create provider")}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    case Synapsis.Providers.delete(id) do
      {:ok, _} ->
        providers = Enum.reject(socket.assigns.providers, &(&1.id == id))
        {:noreply, assign(socket, providers: providers)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete provider")}
    end
  end

  @impl true
  def handle_info({:provider_catalog_changed}, socket) do
    {:ok, providers} = Synapsis.Providers.list()
    {:ok, credentials} = Synapsis.Credentials.list()
    {:noreply, assign(socket, providers: providers, credentials: credentials)}
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp maybe_refresh_models_on_create(provider, preset) do
    if preset.custom or Map.get(preset, :discover_models, false) do
      case Synapsis.Providers.refresh_models(provider.id) do
        {:ok, updated} ->
          {updated, "Provider created; model suggestions loaded. Import models in Manage Models."}

        {:error, _reason} ->
          {provider, "Provider created; model loading failed"}
      end
    else
      {provider, "Provider created"}
    end
  end

  defp new_provider_values(nil), do: %{"name" => "", "base_url" => "", "credential_id" => ""}

  defp new_provider_values(preset) do
    %{"name" => preset.name, "base_url" => preset.base_url, "credential_id" => ""}
  end

  @impl true
  def render(assigns) do
    provider_values =
      react_form_draft(assigns, "create-provider-form") ||
        new_provider_values(assigns.selected_preset)

    credential_options = [
      {"", "No credential"} | Enum.map(assigns.credentials, &{&1.id, &1.name})
    ]

    selected_id = provider_values["credential_id"]

    credential_options =
      if selected_id not in [nil, ""] and
           not Enum.any?(assigns.credentials, &(&1.id == selected_id)),
         do: credential_options ++ [{selected_id, "Credential unavailable"}],
         else: credential_options

    assigns =
      assign(assigns,
        presets: Synapsis.Providers.preset_providers(),
        custom_presets: @custom_presets,
        provider_values: provider_values,
        credential_options: credential_options
      )

    ~H"""
    <.settings_layout current_path="/settings/providers" content_class="max-w-5xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Providers</:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Providers</h1>
        <.dm_btn
          :if={!@show_form}
          variant="primary"
          size="sm"
          phx-click={JS.navigate(~p"/settings/providers/new")}
        >
          + Add Provider
        </.dm_btn>
      </div>

      <%= if @show_form do %>
        <%= if @selected_preset do %>
          <.dm_card variant="bordered" class="mb-6">
            <:title>
              <div class="flex items-center gap-3">
                <.dm_btn variant="ghost" size="xs" phx-click="back_to_presets">
                  &larr; Back
                </.dm_btn>
                <span>
                  <%= if @selected_preset.custom do %>
                    New {@selected_preset.label}
                  <% else %>
                    Add {Map.get(@selected_preset, :label, @selected_preset.name)}
                  <% end %>
                </span>
              </div>
            </:title>
            <.react_form
              for={to_form(%{})}
              id="create-provider-form"
              values={@provider_values}
              draft={react_form_draft(assigns, "create-provider-form")}
              structure={[@selected_preset, @credential_options]}
              phx-change="change_provider_form"
              phx-submit="create_provider"
              class="space-y-3"
            >
              <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 --%>
              <.dm_input
                id="provider-name"
                type="text"
                name="name"
                value={@provider_values["name"]}
                placeholder="Unique name for this provider"
                label="Name"
                required
              />
              <.readonly_field label="Type" value={@selected_preset.type} />
              <%= if @selected_preset.custom or Map.get(@selected_preset, :base_url_editable, false) do %>
                <.dm_input
                  id="provider-base-url"
                  type="text"
                  name="base_url"
                  value={@provider_values["base_url"]}
                  placeholder="https://api.example.com/v1"
                  label="Base URL"
                  required
                />
              <% else %>
                <.readonly_field label="Base URL" value={@selected_preset.base_url} />
              <% end %>
              <.dm_alert :if={@selected_preset.name == "backplane"} variant="info">
                Use http://localhost:4220/v1 for a local Backplane. Choose No credential
                only when that server has authentication disabled. HTTP 401 means a valid token is required.
              </.dm_alert>
              <%= if @selected_preset.name == "openai-sub" do %>
                <div class="bg-info/10 border border-info/30 rounded-lg px-3 py-2 text-sm text-info">
                  This provider uses OAuth authentication. After creating, you'll be redirected
                  to sign in with your ChatGPT account.
                </div>
              <% else %>
                <.dm_select
                  id="provider-credential"
                  name="credential_id"
                  value={@provider_values["credential_id"]}
                  label="Credential"
                  options={@credential_options}
                />
                <.link navigate={~p"/settings/credentials"} class="link text-sm">
                  Manage Credentials
                </.link>
              <% end %>
              <:actions>
                <.dm_btn type="submit" variant="primary">
                  <%= if @selected_preset.name == "openai-sub" do %>
                    Create & Sign In
                  <% else %>
                    Add Provider
                  <% end %>
                </.dm_btn>
              </:actions>
            </.react_form>
          </.dm_card>
        <% else %>
          <div class="mb-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold">Select a Provider</h2>
              <.dm_btn
                variant="ghost"
                size="sm"
                phx-click={JS.navigate(~p"/settings/providers")}
              >
                Cancel
              </.dm_btn>
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <button
                :for={preset <- @presets}
                type="button"
                phx-click="select_preset"
                phx-value-name={preset.name}
                class="block w-full text-left cursor-pointer"
              >
                <.dm_card
                  variant="bordered"
                  class="cursor-pointer hover:border-primary hover:bg-surface-container-high transition-colors h-full"
                >
                  <div class="font-medium">{Map.get(preset, :label, preset.name)}</div>
                  <div class="text-xs text-on-surface-variant mt-1">{preset.type}</div>
                </.dm_card>
              </button>
            </div>

            <h3 class="text-sm font-semibold text-on-surface-variant mt-6 mb-3">Custom</h3>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <button
                :for={custom <- @custom_presets}
                type="button"
                phx-click="select_custom"
                phx-value-type={custom.type}
                class="block w-full text-left cursor-pointer"
              >
                <.dm_card
                  variant="bordered"
                  class="cursor-pointer border-dashed hover:border-primary hover:bg-surface-container-high transition-colors h-full"
                >
                  <div class="font-medium">{custom.label}</div>
                  <div class="text-xs text-on-surface-variant mt-1">Custom base URL</div>
                </.dm_card>
              </button>
            </div>
          </div>
        <% end %>
      <% end %>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <.dm_card
          :for={provider <- @providers}
          variant="bordered"
        >
          <:title>
            <div class="flex justify-between items-start w-full">
              <.dm_link
                navigate={~p"/settings/providers/#{provider.id}"}
                class="font-medium"
              >
                {provider.name}
              </.dm_link>
              <.dm_btn
                variant="ghost"
                size="xs"
                phx-click="delete_provider"
                phx-value-id={provider.id}
                confirm="Delete this provider?"
                class="text-on-surface-variant hover:text-error ml-2"
              >
                Delete
              </.dm_btn>
            </div>
          </:title>
          <div class="text-xs text-on-surface-variant">{provider.type}</div>
          <div :if={provider.base_url} class="text-xs text-on-surface-variant mt-1 truncate">
            {provider.base_url}
          </div>
          <div class="mt-2">
            <.dm_badge :if={provider.enabled} variant="success">
              Enabled
            </.dm_badge>
            <.dm_badge :if={!provider.enabled} variant="error">
              Disabled
            </.dm_badge>
          </div>
        </.dm_card>
      </div>

      <div :if={@providers == [] && !@show_form} class="text-center text-on-surface-variant py-12">
        No providers configured. Click "+ Add Provider" to get started.
      </div>
    </.settings_layout>
    """
  end
end
