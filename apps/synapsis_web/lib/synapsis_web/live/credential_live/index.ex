defmodule SynapsisWeb.CredentialLive.Index do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  alias Synapsis.Credentials

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Synapsis.Providers.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: "Credentials",
       show_form: false,
       editing: nil,
       form_error: nil,
       blocked_delete_id: nil,
       delete_references: []
     )
     |> load_credentials()}
  end

  @impl true
  def handle_event("new_credential", _params, socket) do
    {:noreply,
     socket
     |> reset_react_form("credential-form")
     |> assign(show_form: true, editing: nil, form_error: nil)}
  end

  def handle_event("edit_credential", %{"id" => id}, socket) do
    case Credentials.get(id) do
      {:ok, credential} ->
        {:noreply,
         socket
         |> reset_react_form("credential-form")
         |> assign(show_form: true, editing: credential, form_error: nil)}

      {:error, :not_found} ->
        {:noreply, socket |> load_credentials() |> put_flash(:error, "Credential not found")}
    end
  end

  def handle_event("cancel_credential", _params, socket) do
    {:noreply, close_form(socket)}
  end

  def handle_event("change_credential_form", _params, socket), do: {:noreply, socket}

  def handle_event("save_credential", params, socket) do
    attrs = Map.take(params, ["name", "key"])

    result =
      case socket.assigns.editing do
        nil -> Credentials.create(attrs)
        credential -> Credentials.update(credential.id, attrs)
      end

    case result do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> close_form()
         |> load_credentials()
         |> put_flash(:info, "Credential saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Enum.map_join(changeset.errors, "; ", fn {field, {message, _opts}} ->
            "#{field |> to_string() |> String.capitalize()} #{message}"
          end)

        credential_error(socket, errors)

      {:error, :not_found} ->
        credential_error(socket, "Credential was deleted. Cancel and create a new credential.")

      {:error, _reason} ->
        credential_error(socket, "Failed to save credential")
    end
  end

  def handle_event("delete_credential", %{"id" => id}, socket) do
    case Credentials.delete(id) do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> load_credentials()
         |> put_flash(:info, "Credential deleted")}

      {:error, {:in_use, _references}} ->
        {:noreply, socket |> assign(blocked_delete_id: id) |> load_credentials()}

      {:error, :not_found} ->
        {:noreply, load_credentials(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete credential")}
    end
  end

  @impl true
  def handle_info({:provider_catalog_changed}, socket), do: {:noreply, load_credentials(socket)}

  defp credential_error(socket, message) do
    {:reply, %{status: "error", message: message, errors: %{"_form" => [message]}},
     assign(socket, form_error: message)}
  end

  defp close_form(socket) do
    socket
    |> reset_react_form("credential-form")
    |> assign(show_form: false, editing: nil, form_error: nil)
  end

  defp load_credentials(socket) do
    {:ok, credentials} = Credentials.list()
    references = Map.new(credentials, &{&1.id, Credentials.references(&1.id)})
    delete_references = Map.get(references, socket.assigns.blocked_delete_id, [])

    assign(socket,
      credentials: credentials,
      references: references,
      delete_references: delete_references,
      blocked_delete_id:
        if(delete_references == [], do: nil, else: socket.assigns.blocked_delete_id)
    )
  end

  defp credential_values(nil), do: %{"name" => "", "key" => ""}
  defp credential_values(credential), do: %{"name" => credential.name, "key" => ""}

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_layout current_path="/settings/credentials" content_class="max-w-5xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb>Credentials</:crumb>
      </.breadcrumb>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Credentials</h1>
        <.dm_btn variant="primary" size="sm" phx-click="new_credential">
          + Add Credential
        </.dm_btn>
      </div>

      <div :if={@delete_references != []} role="alert" class="mb-4 text-sm text-error">
        This credential is in use. Change or remove its reference in these Providers before deleting:
        <.link
          :for={provider <- @delete_references}
          navigate={~p"/settings/providers/#{provider.id}"}
          class="link ml-2"
        >
          {provider.name}
        </.link>
      </div>

      <div class="space-y-3">
        <.dm_card :for={credential <- @credentials} variant="bordered">
          <:title>
            <div class="flex items-center justify-between gap-3 w-full">
              <span>{credential.name}</span>
              <div class="flex gap-2">
                <.dm_btn
                  variant="ghost"
                  size="xs"
                  phx-click="edit_credential"
                  phx-value-id={credential.id}
                >
                  Edit
                </.dm_btn>
                <%!-- # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#208 - confirmation currently logs a duplicate dialog-close warning. --%>
                <.dm_btn
                  variant="ghost"
                  size="xs"
                  phx-click="delete_credential"
                  phx-value-id={credential.id}
                  confirm="Delete this credential?"
                  confirm_title="Delete credential?"
                  confirm_text="Delete credential"
                >
                  Delete
                </.dm_btn>
              </div>
            </div>
          </:title>
          <code class="text-sm">{credential.masked_key}</code>
          <div class="text-xs text-on-surface-variant mt-2">
            Updated {DateTime.to_iso8601(credential.updated_at)}
          </div>
          <div class="text-sm mt-2">
            <span :if={@references[credential.id] == []} class="text-on-surface-variant">
              No Providers use this credential.
            </span>
            <.link
              :for={provider <- @references[credential.id]}
              navigate={~p"/settings/providers/#{provider.id}"}
              class="link mr-3"
            >
              {provider.name}
            </.link>
          </div>
        </.dm_card>
      </div>

      <p :if={@credentials == []} class="text-center text-on-surface-variant py-12">
        No credentials configured. Add a credential to use it with your Providers.
      </p>

      <.dm_modal
        :if={@show_form}
        id="credential-modal"
        size="md"
        class="synapsis-mcp-modal"
        phx-hook="MCPFormModal"
        data-close-event="cancel_credential"
      >
        <:title>{if @editing, do: "Edit Credential", else: "Add Credential"}</:title>
        <:body>
          <div :if={@form_error} role="alert" aria-live="polite" class="mb-4 text-error text-sm">
            {@form_error}
          </div>
          <.react_form
            for={%{}}
            id="credential-form"
            values={credential_values(@editing)}
            draft={react_form_draft(assigns, "credential-form")}
            structure={@editing && @editing.id}
            phx-submit="save_credential"
            phx-change="change_credential_form"
            class="space-y-4"
          >
            <.dm_input
              id="credential-name"
              type="text"
              name="name"
              value={if @editing, do: @editing.name, else: ""}
              label="Name"
              required
            />
            <.dm_input
              id="credential-key"
              type="password"
              name="key"
              value=""
              autocomplete="new-password"
              label="Secret Key"
              placeholder={
                if @editing, do: "Leave empty to keep the current key", else: "Enter secret key"
              }
              required={is_nil(@editing)}
            />
            <:actions>
              <%!-- # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#88 - native submission avoids duplicate requests after modal reconnect. --%>
              <.dm_btn type="submit" native_submit variant="primary">
                {if @editing, do: "Save Changes", else: "Add Credential"}
              </.dm_btn>
              <.dm_btn type="button" variant="ghost" phx-click="cancel_credential">Cancel</.dm_btn>
            </:actions>
          </.react_form>
        </:body>
      </.dm_modal>
    </.settings_layout>
    """
  end
end
