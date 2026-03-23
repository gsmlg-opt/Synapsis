defmodule SynapsisWeb.ProviderLive.Index do
  use SynapsisWeb, :live_view

  @custom_presets [
    %{name: "", type: "openai", base_url: "", label: "OpenAI Compatible", custom: true},
    %{name: "", type: "anthropic", base_url: "", label: "Anthropic Compatible", custom: true}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, providers: [], page_title: "Providers")}
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

    {:noreply, assign(socket, selected_preset: Map.put(preset, :custom, false))}
  end

  def handle_event("select_custom", %{"type" => type}, socket) do
    preset = Enum.find(@custom_presets, &(&1.type == type))
    {:noreply, assign(socket, selected_preset: preset)}
  end

  def handle_event("back_to_presets", _params, socket) do
    {:noreply, assign(socket, selected_preset: nil)}
  end

  def handle_event("create_provider", params, socket) do
    preset = socket.assigns.selected_preset

    attrs = %{
      name: params["name"],
      type: preset.type,
      base_url: if(preset.custom, do: params["base_url"], else: preset.base_url),
      api_key_encrypted: params["api_key"]
    }

    # For OAuth providers, api_key is optional
    attrs =
      if attrs.api_key_encrypted in [nil, ""] do
        Map.delete(attrs, :api_key_encrypted)
      else
        attrs
      end

    case Synapsis.Providers.create(attrs) do
      {:ok, provider} ->
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
         |> put_flash(:info, "Provider created")
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
  def render(assigns) do
    assigns =
      assign(assigns,
        presets: Synapsis.Providers.preset_providers(),
        custom_presets: @custom_presets
      )

    ~H"""
    <div class="max-w-5xl mx-auto p-6">
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
                    Add {@selected_preset.name}
                  <% end %>
                </span>
              </div>
            </:title>
            <.dm_form for={to_form(%{})} phx-submit="create_provider" class="space-y-3">
              <.dm_input
                type="text"
                name="name"
                value={@selected_preset.name}
                placeholder="Unique name for this provider"
                label="Name"
                required
              />
              <.readonly_field label="Type" value={@selected_preset.type} />
              <%= if @selected_preset.custom do %>
                <.dm_input
                  type="text"
                  name="base_url"
                  value=""
                  placeholder="https://api.example.com"
                  label="Base URL"
                  required
                />
              <% else %>
                <.readonly_field label="Base URL" value={@selected_preset.base_url} />
              <% end %>
              <%= if @selected_preset.name == "openai-sub" do %>
                <div class="bg-info/10 border border-info/30 rounded-lg px-3 py-2 text-sm text-info">
                  This provider uses OAuth authentication. After creating, you'll be redirected
                  to sign in with your ChatGPT account.
                </div>
              <% else %>
                <.dm_input
                  type="password"
                  name="api_key"
                  value=""
                  placeholder="Enter API key"
                  label="API Key"
                  required
                />
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
            </.dm_form>
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
                phx-click="select_preset"
                phx-value-name={preset.name}
                class="text-left"
              >
                <.dm_card
                  variant="bordered"
                  class="cursor-pointer hover:border-primary hover:bg-base-300 transition-colors h-full"
                >
                  <div class="font-medium">{preset.name}</div>
                  <div class="text-xs text-base-content/50 mt-1">{preset.type}</div>
                </.dm_card>
              </button>
            </div>

            <h3 class="text-sm font-semibold text-base-content/50 mt-6 mb-3">Custom</h3>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <button
                :for={custom <- @custom_presets}
                phx-click="select_custom"
                phx-value-type={custom.type}
                class="text-left"
              >
                <.dm_card
                  variant="bordered"
                  class="cursor-pointer border-dashed hover:border-primary hover:bg-base-300 transition-colors h-full"
                >
                  <div class="font-medium">{custom.label}</div>
                  <div class="text-xs text-base-content/50 mt-1">Custom base URL</div>
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
                class="text-base-content/40 hover:text-error ml-2"
              >
                Delete
              </.dm_btn>
            </div>
          </:title>
          <div class="text-xs text-base-content/50">{provider.type}</div>
          <div :if={provider.base_url} class="text-xs text-base-content/40 mt-1 truncate">
            {provider.base_url}
          </div>
          <div class="mt-2">
            <.dm_badge :if={provider.enabled} color="success">
              Enabled
            </.dm_badge>
            <.dm_badge :if={!provider.enabled} color="error">
              Disabled
            </.dm_badge>
          </div>
        </.dm_card>
      </div>

      <div :if={@providers == [] && !@show_form} class="text-center text-base-content/40 py-12">
        No providers configured. Click "+ Add Provider" to get started.
      </div>
    </div>
    """
  end
end
