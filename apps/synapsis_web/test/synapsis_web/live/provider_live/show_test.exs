defmodule SynapsisWeb.ProviderLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, provider} =
      %Synapsis.ProviderConfig{}
      |> Synapsis.ProviderConfig.changeset(%{
        name: "test-show-provider-#{:rand.uniform(100_000)}",
        type: "anthropic",
        api_key_encrypted: "sk-ant-test-key"
      })
      |> Synapsis.Repo.insert()

    {:ok, provider: provider}
  end

  describe "provider show page" do
    test "mounts and displays provider name", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ provider.name
    end

    test "shows provider type (read-only)", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ provider.type
    end

    test "shows api key is set indicator", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Key is set"
    end

    test "shows save button", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert has_element?(view, "button[type='submit']", "Save Changes")
    end

    test "redirects for unknown provider id", %{conn: conn} do
      id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/settings/providers"}}} =
               live(conn, ~p"/settings/providers/#{id}")
    end

    test "update_provider event updates base_url", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      html =
        view
        |> form("form", %{
          "base_url" => "https://custom.api.example.com/v1",
          "enabled" => "true"
        })
        |> render_submit()

      assert html =~ "Provider updated"
    end

    test "shows breadcrumb with Settings / Providers / name", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Settings"
      assert html =~ "Providers"
      assert html =~ provider.name
    end

    test "update_provider with enabled=false disables the provider", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{"base_url" => "", "enabled" => "false"})
      |> render_submit()

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.enabled == false
    end

    test "update_provider with empty api_key does not overwrite existing key", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{"base_url" => "", "enabled" => "true", "api_key" => ""})
      |> render_submit()

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.api_key_encrypted != nil
    end

    test "update_provider with new api_key updates it", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{"base_url" => "", "enabled" => "true", "api_key" => "new-secret-key"})
      |> render_submit()

      html = render(view)
      assert html =~ "Provider updated"
    end

    test "provider without api_key does not show 'Key is set'", %{conn: conn} do
      {:ok, no_key_provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "no-key-prov-#{:rand.uniform(100_000)}",
          type: "openai_compat"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{no_key_provider.id}")
      refute html =~ "Key is set"
    end

    test "heading displays the provider name", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert has_element?(view, "h1", provider.name)
    end

    test "form has base_url input field", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Base URL"
      assert html =~ "base_url"
    end

    test "form has enabled checkbox", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Enabled"
      assert html =~ ~s(name="enabled")
    end

    test "update_provider with new base_url persists it", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{
        "base_url" => "https://new-base.example.com/v2",
        "enabled" => "true"
      })
      |> render_submit()

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.base_url == "https://new-base.example.com/v2"
    end

    test "shows models section for anthropic provider", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Models"
      assert html =~ "Claude"
    end

    test "shows all models enabled by default", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "All models enabled"
    end

    test "edit button toggles model editing mode", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      html =
        view
        |> element(~s(button[phx-click="toggle_edit_models"]))
        |> render_click()

      assert html =~ "Save Models"
      assert html =~ ~s(name="models[]")
    end

    test "save_models persists enabled models", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      # Enter edit mode
      view
      |> element(~s(button[phx-click="toggle_edit_models"]))
      |> render_click()

      # Submit with specific models selected
      html =
        view
        |> form("form[phx-submit='save_models']", %{
          "models" => ["claude-sonnet-4-6", "claude-haiku-3-5-20241022"]
        })
        |> render_submit()

      assert html =~ "Models updated"

      # Verify persisted
      {:ok, updated} = Synapsis.Providers.get(provider.id)

      assert updated.config["enabled_models"] == [
               "claude-sonnet-4-6",
               "claude-haiku-3-5-20241022"
             ]
    end

    test "disabled models shown differently from enabled", %{conn: conn} do
      {:ok, provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "filtered-prov-#{:rand.uniform(100_000)}",
          type: "anthropic",
          api_key_encrypted: "sk-key",
          config: %{"enabled_models" => ["claude-sonnet-4-6"]}
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      # Should not show "All models enabled" since a filter is set
      refute html =~ "All models enabled"
    end

    test "test chat section is present", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Test Chat"
    end

    test "toggle_chat opens and closes the chat panel", %{conn: conn, provider: provider} do
      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      refute html =~ "Send a message to test"

      html =
        view
        |> element(~s(div[phx-click="toggle_chat"]))
        |> render_click()

      assert html =~ "Send a message to test"

      html =
        view
        |> element(~s(div[phx-click="toggle_chat"]))
        |> render_click()

      refute html =~ "Send a message to test"
    end

    test "chat panel shows model selector", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      html =
        view
        |> element(~s(div[phx-click="toggle_chat"]))
        |> render_click()

      assert html =~ "Claude"
      assert html =~ ~s(phx-change="chat_select_model")
    end

    test "chat_select_model changes selected model", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      html = render_hook(view, "chat_select_model", %{"model" => "claude-haiku-3-5-20241022"})
      assert html =~ "claude-haiku-3-5-20241022"
    end

    test "chat_send with empty message does nothing", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      html = render_hook(view, "chat_send", %{"message" => ""})
      refute html =~ "Provider not registered"
    end

    test "chat_send without registered provider shows error", %{conn: conn, provider: provider} do
      # Ensure provider is not in the registry
      Synapsis.Provider.Registry.unregister(provider.name)

      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      html = render_hook(view, "chat_send", %{"message" => "hello"})
      assert html =~ "Provider not registered"
    end

    test "chat_clear resets messages", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      render_hook(view, "chat_clear", %{})
      html = render(view)
      assert html =~ "Send a message to test"
    end

    test "handle_info for provider_done appends assistant message", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      # Simulate streaming lifecycle via handle_info
      send(view.pid, {:provider_chunk, {:text_delta, "Hello "}})
      send(view.pid, {:provider_chunk, {:text_delta, "world!"}})
      send(view.pid, :provider_done)

      # Give the view a moment to process
      html = render(view)
      assert html =~ "Hello world!"
    end

    test "handle_info for provider_error shows error message", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      send(view.pid, {:provider_error, "HTTP 401: Invalid API key"})

      html = render(view)
      assert html =~ "Error: HTTP 401"
    end
  end
end
