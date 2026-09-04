defmodule SynapsisWeb.ProviderLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    provider =
      create_provider!(%{
        name: "test-show-provider",
        type: "anthropic",
        api_key_encrypted: "sk-ant-test-key"
      })

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
      assert has_element?(view, "el-dm-button[type='submit']", "Save Changes")
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

    test "clears a stored token and refreshes models without authorization", %{conn: conn} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        headers = Map.new(conn.req_headers)
        refute Map.has_key?(headers, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "backplane-model"}]}))
      end)

      provider =
        create_provider!(%{
          name: "backplane-clear",
          type: "openai",
          base_url: "http://localhost:#{bypass.port}/v1",
          api_key_encrypted: "placeholder-token",
          config: %{"available_models" => [%{"id" => "old-model", "name" => "Old Model"}]}
        })

      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Key is set"
      assert html =~ "Clear stored token"
      assert has_element?(view, ~s(#clear-provider-api-key[command="show-modal"]))
      assert has_element?(view, ~s(dialog[data-dm-confirm-dialog="true"]))

      assert has_element?(
               view,
               ~s(button[data-dm-confirm-action="true"][phx-click="clear_api_key"]),
               "Clear token"
             )

      html =
        view
        |> element(~s(button[data-dm-confirm-action="true"][phx-click="clear_api_key"]))
        |> render_click()

      assert html =~ "Access token cleared"
      refute html =~ "Key is set"

      assert {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert is_nil(updated.api_key_encrypted)
      assert {:ok, %{api_key: nil}} = Synapsis.Provider.Registry.get(provider.name)

      assert :ok = Synapsis.Config.Store.reload(:provider)
      assert {:ok, raw} = Synapsis.Config.Store.get(:provider, provider.id)
      refute Map.has_key?(raw, "api_key_encrypted")

      html =
        view
        |> element(~s(el-dm-button[phx-click="refresh_models"]))
        |> render_click()

      assert html =~ "Models refreshed"
      assert html =~ "backplane-model"
    end

    test "clearing an absent token remains keyless", %{conn: conn} do
      provider =
        create_provider!(%{
          name: "already-keyless",
          type: "openai",
          base_url: "http://localhost:4220/v1",
          config: %{"available_models" => [%{"id" => "cached-model", "name" => "Cached Model"}]}
        })

      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      refute html =~ "Key is set"

      html = render_hook(view, "clear_api_key", %{})
      assert html =~ "Access token cleared"

      assert {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert is_nil(updated.api_key_encrypted)
      assert {:ok, %{api_key: nil}} = Synapsis.Provider.Registry.get(provider.name)
    end

    test "does not offer or clear a stored token for an OAuth provider", %{conn: conn} do
      provider =
        create_provider!(%{
          name: "oauth-keyed",
          type: "openai",
          base_url: "http://localhost:4220/v1",
          api_key_encrypted: "stored-api-key",
          config: %{
            "auth_mode" => "oauth_device",
            "available_models" => [%{"id" => "cached-model", "name" => "Cached Model"}],
            "oauth_tokens" => %{"access_token" => "oauth-access-token"}
          }
        })

      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      refute html =~ "Clear stored token"
      refute has_element?(view, "#clear-provider-api-key")

      assert {:ok, %{api_key: "oauth-access-token", oauth: true}} =
               Synapsis.Provider.Registry.get(provider.name)

      html = render_hook(view, "clear_api_key", %{})
      assert html =~ "OAuth credentials must be managed through OAuth login"

      assert {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.api_key_encrypted == "stored-api-key"
      assert updated.config["oauth_tokens"]["access_token"] == "oauth-access-token"

      assert {:ok, %{api_key: "oauth-access-token", oauth: true}} =
               Synapsis.Provider.Registry.get(provider.name)
    end

    test "rejects a stale clear event after the provider switches to OAuth", %{conn: conn} do
      provider =
        create_provider!(%{
          name: "stale-clear-oauth",
          type: "openai",
          base_url: "http://localhost:4220/v1",
          api_key_encrypted: "stored-api-key",
          config: %{"available_models" => [%{"id" => "cached-model", "name" => "Cached Model"}]}
        })

      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      assert {:ok, _} =
               Synapsis.Providers.update(provider.id, %{
                 config: %{
                   "auth_mode" => "oauth_device",
                   "available_models" => [%{"id" => "cached-model", "name" => "Cached Model"}],
                   "oauth_tokens" => %{"access_token" => "oauth-token"}
                 }
               })

      html = render_hook(view, "clear_api_key", %{})
      assert html =~ "OAuth credentials must be managed through OAuth login"
      refute html =~ "Clear stored token"
      refute html =~ "Key is set"

      assert {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.api_key_encrypted == "stored-api-key"

      assert {:ok, %{api_key: "oauth-token", oauth: true}} =
               Synapsis.Provider.Registry.get(provider.name)
    end

    test "provider without api_key does not show 'Key is set'", %{conn: conn} do
      no_key_provider =
        create_provider!(%{
          name: "no-key-prov",
          type: "openai_compat"
        })

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
        |> element(~s(el-dm-button[phx-click="toggle_edit_models"]))
        |> render_click()

      assert html =~ "Save Models"
      assert html =~ ~s(name="models[]")
    end

    test "refresh_models reloads models from provider settings", %{conn: conn} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "fresh-model"}]}))
      end)

      provider =
        create_provider!(%{
          name: "refreshable-provider",
          type: "openai",
          base_url: "http://localhost:#{bypass.port}/v1",
          api_key_encrypted: "sk-test",
          config: %{"available_models" => [%{"id" => "old-model", "name" => "Old Model"}]}
        })

      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Old Model"

      html =
        view
        |> element(~s(el-dm-button[phx-click="refresh_models"]))
        |> render_click()

      assert html =~ "Models refreshed"
      assert html =~ "fresh-model"

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert [%{"id" => "fresh-model"}] = updated.config["available_models"]
    end

    test "save_models persists enabled models", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      # Enter edit mode
      view
      |> element(~s(el-dm-button[phx-click="toggle_edit_models"]))
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
      provider =
        create_provider!(%{
          name: "filtered-prov",
          type: "anthropic",
          api_key_encrypted: "sk-key",
          config: %{"enabled_models" => ["claude-sonnet-4-6"]}
        })

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
      assert has_element?(view, "form#provider-chat-model-form")
      assert_unique_form_ids(html)
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
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      # Simulate a stale open page after its provider has been deleted. Available
      # persisted providers are intentionally rebuilt by the runtime resolver.
      assert {:ok, _deleted} = Synapsis.Providers.delete(provider.id)

      html = render_hook(view, "chat_send", %{"message" => "hello"})
      assert html =~ "Provider not registered"
    end

    test "chat_send rejects an unavailable provider despite a stale registry entry", %{conn: conn} do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
        send(test_pid, :provider_http_called)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      provider =
        create_provider!(%{
          name: "unavailable-chat",
          type: "openai",
          base_url: "http://localhost:#{bypass.port}",
          api_key_encrypted: "stale-secret",
          config: %{
            "managed_by" => "backplane",
            "backplane_source_id" => "source-1",
            "backplane_available" => false,
            "available_models" => [%{"id" => "stale-model", "name" => "Stale Model"}]
          }
        })

      :ok =
        Synapsis.Provider.Registry.register(provider.name, %{
          type: "openai",
          base_url: "http://localhost:#{bypass.port}",
          api_key: "stale-secret"
        })

      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      html = render_hook(view, "chat_send", %{"message" => "must not leave the process"})

      refute_receive :provider_http_called, 200
      assert {:error, :not_found} = Synapsis.Provider.Registry.get(provider.name)
      assert html =~ "Provider is currently unavailable"
    end

    test "chat_send rejects a source-disabled model before an HTTP request", %{conn: conn} do
      bypass = Bypass.open()
      test_pid = self()

      assert {:ok, _connection} =
               Synapsis.Config.Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

      Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
        send(test_pid, :provider_http_called)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      provider =
        create_provider!(%{
          name: "mixed-model-chat",
          type: "openai",
          base_url: "http://localhost:#{bypass.port}",
          config: %{
            "managed_by" => "backplane",
            "backplane_source_id" => "source-1",
            "backplane_available" => true,
            "available_models" => [
              %{id: "disabled-model", name: "Disabled Model"},
              %{id: "enabled-model", name: "Enabled Model"}
            ],
            "backplane_models" => [
              %{
                "external_id" => "disabled-model",
                "source_available" => false,
                "backplane_available" => false
              },
              %{
                "external_id" => "enabled-model",
                "source_available" => true,
                "backplane_available" => true
              }
            ]
          }
        })

      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")

      refute html =~ "Disabled Model"
      assert html =~ "Enabled Model"

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      render_hook(view, "chat_select_model", %{"model" => "disabled-model"})
      html = render_hook(view, "chat_send", %{"message" => "must not leave the process"})

      refute_receive :provider_http_called, 200
      assert html =~ "Model is currently unavailable"
    end

    test "chat_send preserves available non-Backplane providers", %{conn: conn} do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
        send(test_pid, :local_provider_http_called)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      provider =
        create_provider!(%{
          name: "local-chat",
          type: "openai",
          base_url: "http://localhost:#{bypass.port}",
          config: %{
            "available_models" => [%{"id" => "local-model", "name" => "Local Model"}]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      html = render_hook(view, "chat_send", %{"message" => "hello"})

      assert_receive :local_provider_http_called, 1_000
      refute html =~ "Provider is currently unavailable"
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

  defp create_provider!(attrs) do
    attrs = Map.update!(attrs, :name, &"#{&1}-#{Ecto.UUID.generate()}")
    {:ok, provider} = Synapsis.Providers.create(attrs)
    on_exit(fn -> Synapsis.Providers.delete(provider.id) end)
    provider
  end
end
