defmodule SynapsisWeb.CredentialLive.IndexTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Credentials, Providers}

  test "credential key parameters are redacted from event logs", %{conn: conn} do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    {:ok, view, _} = live(conn, ~p"/settings/credentials")
    render_click(element(view, "[phx-click='new_credential']"))
    secret = "never-log-credential-1234"

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        react_form_change(view, "credential-form", %{"name" => "Log test", "key" => secret})
      end)

    refute log =~ secret

    assert Phoenix.Logger.filter_values(%{
             "values" => %{"key" => secret, "api_key_encrypted" => secret}
           }) ==
             %{"values" => %{"key" => "[FILTERED]", "api_key_encrypted" => "[FILTERED]"}}
  end

  test "lists safe credential metadata and provider references", %{conn: conn} do
    credential = credential!("Shared credential", "sk-secret-123456789")

    {:ok, provider} =
      Providers.create(%{name: "credential-user", type: "openai", credential_id: credential.id})

    on_exit(fn -> Providers.delete(provider.id) end)

    {:ok, view, html} = live(conn, ~p"/settings/credentials")
    assert has_element?(view, "h1", "Credentials")
    assert html =~ credential.name
    assert html =~ credential.masked_key
    assert has_element?(view, "a[href='/settings/providers/#{provider.id}']", provider.name)
    refute html =~ "sk-secret-123456789"
    refute has_element?(view, "[data-form-id='credential-form']")
  end

  test "creates through a modal and clears the successful secret draft", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/credentials")
    render_click(element(view, "[phx-click='new_credential']"))

    assert has_element?(
             view,
             "dialog#credential-modal[phx-hook='MCPFormModal'][data-close-event='cancel_credential']"
           )

    assert has_element?(view, "input[name='key'][type='password'][value='']")
    assert has_element?(view, "button[type='submit']", "Add Credential")

    react_form_submit(view, "credential-form", %{
      "name" => "Created credential",
      "key" => "created-secret-987654"
    })

    refute has_element?(view, "dialog#credential-modal")
    assert {:ok, credentials} = Credentials.list()
    credential = Enum.find(credentials, &(&1.name == "Created credential"))
    assert credential
    on_exit(fn -> Credentials.delete(credential.id) end)
    refute render(view) =~ "created-secret-987654"

    render_click(element(view, "[phx-click='new_credential']"))
    assert form_values(view) == %{"name" => "", "key" => ""}
  end

  test "edit never preloads the old key and blank key preserves it", %{conn: conn} do
    credential = credential!("Original name", "sk-existing-secret-4567")
    {:ok, view, _} = live(conn, ~p"/settings/credentials")
    render_click(element(view, "[phx-click='edit_credential'][phx-value-id='#{credential.id}']"))
    assert form_values(view) == %{"name" => "Original name", "key" => ""}
    refute render(view) =~ "sk-existing-secret-4567"

    react_form_submit(view, "credential-form", %{"name" => "Renamed", "key" => ""})
    assert {:ok, updated} = Credentials.get(credential.id)
    assert updated.name == "Renamed"
    assert updated.masked_key == credential.masked_key
    assert {:ok, "sk-existing-secret-4567"} = Credentials.resolve(credential.id)
    refute has_element?(view, "dialog#credential-modal")
  end

  test "editing rotates the same credential and never displays the saved key", %{conn: conn} do
    credential = credential!("Rotating credential", "old-secret-1234")
    {:ok, view, _} = live(conn, ~p"/settings/credentials")
    render_hook(view, "edit_credential", %{"id" => credential.id})

    react_form_submit(view, "credential-form", %{
      "name" => credential.name,
      "key" => "rotated-secret-5678"
    })

    assert {:ok, "rotated-secret-5678"} = Credentials.resolve(credential.id)
    refute render(view) =~ "rotated-secret-5678"
    render_hook(view, "edit_credential", %{"id" => credential.id})
    assert form_values(view) == %{"name" => credential.name, "key" => ""}
    refute render(view) =~ "old-secret-1234"
    refute render(view) =~ "rotated-secret-5678"
  end

  test "cancel resets a rejected form before reopen", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/credentials")
    render_hook(view, "new_credential", %{})
    react_form_submit(view, "credential-form", %{"name" => "", "key" => "discard-secret"})
    assert has_element?(view, "dialog#credential-modal [role='alert']")
    render_hook(view, "cancel_credential", %{})
    render_hook(view, "new_credential", %{})
    assert form_values(view) == %{"name" => "", "key" => ""}
    refute render(view) =~ "discard-secret"
    refute has_element?(view, "dialog#credential-modal [role='alert']")
  end

  test "refuses referenced deletion and lists the provider until detached", %{conn: conn} do
    credential = credential!("Protected credential", "delete-secret-123456")

    {:ok, provider} =
      Providers.create(%{name: "protected-user", type: "openai", credential_id: credential.id})

    on_exit(fn -> Providers.delete(provider.id) end)
    {:ok, view, _} = live(conn, ~p"/settings/credentials")

    assert has_element?(
             view,
             "button[data-dm-confirm-action='true'][phx-click='delete_credential'][phx-value-id='#{credential.id}']"
           )

    render_click(
      element(
        view,
        "button[data-dm-confirm-action='true'][phx-click='delete_credential'][phx-value-id='#{credential.id}']"
      )
    )

    assert has_element?(view, "[role='alert']", "protected-user")
    assert {:ok, _} = Credentials.get(credential.id)

    assert {:ok, _} = Providers.update(provider.id, %{credential_id: nil})

    render_click(
      element(
        view,
        "button[data-dm-confirm-action='true'][phx-click='delete_credential'][phx-value-id='#{credential.id}']"
      )
    )

    assert {:error, :not_found} = Credentials.get(credential.id)
    refute has_element?(view, "[phx-click='edit_credential'][phx-value-id='#{credential.id}']")
  end

  test "blocked deletion references refresh and the alert clears after the last detach", %{
    conn: conn
  } do
    credential = credential!("Shared blocked credential", "blocked-secret-123456")

    {:ok, first} =
      Providers.create(%{name: "blocked-first", type: "openai", credential_id: credential.id})

    {:ok, second} =
      Providers.create(%{name: "blocked-second", type: "openai", credential_id: credential.id})

    on_exit(fn ->
      Providers.delete(first.id)
      Providers.delete(second.id)
    end)

    {:ok, view, _} = live(conn, ~p"/settings/credentials")
    render_hook(view, "delete_credential", %{"id" => credential.id})

    assert has_element?(
             view,
             "[role='alert'] a[href='/settings/providers/#{first.id}']",
             first.name
           )

    assert has_element?(
             view,
             "[role='alert'] a[href='/settings/providers/#{second.id}']",
             second.name
           )

    assert {:ok, _} = Providers.update(second.id, %{credential_id: nil})
    send(view.pid, {:provider_catalog_changed})

    assert has_element?(
             view,
             "[role='alert'] a[href='/settings/providers/#{first.id}']",
             first.name
           )

    refute has_element?(view, "[role='alert'] a[href='/settings/providers/#{second.id}']")
    refute has_element?(view, "a[href='/settings/providers/#{second.id}']")

    assert {:ok, _} = Providers.update(first.id, %{credential_id: nil})
    send(view.pid, {:provider_catalog_changed})

    refute has_element?(view, "[role='alert']", "This credential is in use.")
    assert {:ok, _} = Credentials.get(credential.id)
    assert has_element?(view, "[phx-click='edit_credential'][phx-value-id='#{credential.id}']")
  end

  test "catalog updates refresh metadata without losing an open edit draft", %{conn: conn} do
    credential = credential!("Credential to edit", "original-secret-1234")
    {:ok, view, _} = live(conn, ~p"/settings/credentials")
    render_hook(view, "edit_credential", %{"id" => credential.id})

    react_form_change(view, "credential-form", %{
      "name" => "Unsaved name",
      "key" => "replacement-secret"
    })

    credential!("New credential elsewhere", "another-secret-5678")
    send(view.pid, {:provider_catalog_changed})
    assert render(view) =~ "New credential elsewhere"
    assert form_values(view) == %{"name" => "Unsaved name", "key" => "replacement-secret"}
  end

  defp credential!(name, key) do
    {:ok, credential} = Credentials.create(%{name: name, key: key})
    on_exit(fn -> Credentials.delete(credential.id) end)
    credential
  end

  defp form_values(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-form-id='credential-form']")
    |> LazyHTML.attribute("data-initial-values")
    |> hd()
    |> Jason.decode!()
  end
end
