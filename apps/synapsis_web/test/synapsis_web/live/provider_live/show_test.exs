defmodule SynapsisWeb.ProviderLive.ShowTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

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
        |> react_form_submit("edit-provider-form", %{
          "base_url" => "https://custom.api.example.com/v1",
          "enabled" => true
        })

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
      |> react_form_submit("edit-provider-form", %{"base_url" => "", "enabled" => false})

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.enabled == false
    end

    test "update_provider with empty api_key does not overwrite existing key", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> react_form_submit("edit-provider-form", %{
        "base_url" => "",
        "enabled" => true,
        "api_key" => ""
      })

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.api_key_encrypted != nil
    end

    test "update_provider with new api_key updates it", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> react_form_submit("edit-provider-form", %{
        "base_url" => "",
        "enabled" => true,
        "api_key" => "new-secret-key"
      })

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

    test "clearing a token preserves noncredential edits and discards the typed key", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      draft_url = "https://edited.api.example.com/v1"

      react_form_change(view, "edit-provider-form", %{
        "base_url" => draft_url,
        "enabled" => false,
        "api_key" => "discard-this-typed-key"
      })

      render_hook(view, "clear_api_key", %{})

      assert_push_event(view, "dm:form:reset", %{
        form_id: "edit-provider-form",
        values: %{"base_url" => ^draft_url, "enabled" => false, "api_key" => ""}
      })

      assert {:ok, before_save} = Synapsis.Providers.get(provider.id)
      assert before_save.base_url == provider.base_url
      assert before_save.enabled == provider.enabled
      assert is_nil(before_save.api_key_encrypted)

      react_form_submit(view, "edit-provider-form", %{})
      assert {:ok, saved} = Synapsis.Providers.get(provider.id)
      assert saved.base_url == draft_url
      refute saved.enabled
      assert is_nil(saved.api_key_encrypted)
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
      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Enabled"
      assert has_element?(view, ~s|[data-dm-react-field*='"enabled"']|)
    end

    test "update_provider with new base_url persists it", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> react_form_submit("edit-provider-form", %{
        "base_url" => "https://new-base.example.com/v2",
        "enabled" => true
      })

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.base_url == "https://new-base.example.com/v2"
    end

    test "shows models section for anthropic provider", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Models"
      assert html =~ "Claude"
    end

    test "connection settings link to the independent model catalog", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert has_element?(view, "a[href='/settings/models']", "Manage Models")
      refute has_element?(view, "[phx-click='toggle_edit_models']")
      refute has_element?(view, "[data-form-id='provider-models-form']")
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

    test "test chat section is present", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Test Chat"
    end

    test "toggle_chat opens and closes the chat panel", %{conn: conn, provider: provider} do
      {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      refute html =~ ~s(phx-hook="SynapsisReactChat")

      html =
        view
        |> element(~s(div[phx-click="toggle_chat"]))
        |> render_click()

      assert html =~ ~s(phx-hook="SynapsisReactChat")

      html =
        view
        |> element(~s(div[phx-click="toggle_chat"]))
        |> render_click()

      refute html =~ ~s(phx-hook="SynapsisReactChat")
    end

    test "chat panel shows model selector", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      html =
        view
        |> element(~s(div[phx-click="toggle_chat"]))
        |> render_click()

      assert html =~ "Claude"
      assert html =~ ~s(phx-change="chat_select_model")

      assert has_element?(
               view,
               "[data-form-id='provider-chat-model-form'][phx-hook='DuskmoonReactForm']"
             )

      assert_unique_form_ids(html)
    end

    test "chat_select_model changes selected model", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      html =
        react_form_change(view, "provider-chat-model-form", %{
          "model" => "claude-haiku-3-5-20241022"
        })

      assert html =~ "claude-haiku-3-5-20241022"
    end

    test "chat_send with empty message does nothing", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      html = render_hook(view, "chat.send", chat_params(provider, %{"text" => ""}))
      refute html =~ "Provider not registered"
      assert_reply view, %{status: "error", message: "Enter a message"}
    end

    test "chat_send without registered provider shows error", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      # Simulate a stale open page after its provider has been deleted. Available
      # persisted providers are intentionally rebuilt by the runtime resolver.
      assert {:ok, _deleted} = Synapsis.Providers.delete(provider.id)

      render_hook(view, "chat.send", chat_params(provider, %{"text" => "hello"}))

      assert_reply view, %{
        status: "error",
        message: "Provider not registered. Save and enable it first."
      }

      assert_push_event view, "chat:event", %{
        type: "chat.message",
        message: %{status: "error", error: "Provider not registered. Save and enable it first."}
      }
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

      render_hook(
        view,
        "chat.send",
        chat_params(provider, %{"text" => "must not leave the process"})
      )

      refute_receive :provider_http_called, 200
      assert {:error, :not_found} = Synapsis.Provider.Registry.get(provider.name)
      assert_reply view, %{status: "error", message: "Provider is currently unavailable."}
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

      react_form_change(view, "provider-chat-model-form", %{"model" => "disabled-model"})

      render_hook(
        view,
        "chat.send",
        chat_params(provider, %{"text" => "must not leave the process"})
      )

      refute_receive :provider_http_called, 200
      assert_reply view, %{status: "error", message: "Model is currently unavailable."}
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

      render_hook(view, "chat.send", chat_params(provider, %{"text" => "hello"}))

      assert_reply view, %{status: "ok"}
      assert_receive :local_provider_http_called, 1_000
    end

    test "chat_clear resets messages", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> element(~s(div[phx-click="toggle_chat"]))
      |> render_click()

      render_hook(view, "chat_clear", %{})
      html = render(view)
      assert html =~ ~s(phx-hook="SynapsisReactChat")
    end

    test "React chat scopes requests and restores canonical state", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      render_hook(view, "toggle_chat", %{})

      render_hook(
        view,
        "chat.send",
        chat_params(provider, %{"conversation_id" => "other", "text" => "hello"})
      )

      assert_reply view, %{status: "error", message: "Conversation is no longer available"}

      render_hook(
        view,
        "chat.send",
        chat_params(provider, %{"request_id" => nil, "text" => "hello"})
      )

      assert_reply view, %{status: "error", message: "Invalid request ID"}

      render_hook(
        view,
        "chat.send",
        chat_params(provider, %{"text" => "hello", "images" => [%{}]})
      )

      assert_reply view, %{
        status: "error",
        message: "Provider test chat does not support attachments"
      }

      render_hook(view, "chat.sync", chat_params(provider))
      assert_reply view, %{status: "ok"}

      assert_push_event view, "chat:event", %{
        type: "chat.snapshot",
        messages: [],
        metadata: %{kind: "provider", attachmentsAllowed: false, canStop: true},
        runtime: %{active: false},
        admission: %{canSubmit: true}
      }
    end

    test "provider stream sends ordered deltas and preserves its assistant ID", %{conn: conn} do
      {provider, _bypass} = controlled_chat_provider(self())
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      render_hook(view, "toggle_chat", %{})
      render_hook(view, "chat.send", chat_params(provider, %{"text" => "hello"}))
      assert_reply view, %{status: "ok"}
      assert_receive {:provider_request, request_pid}, 1_000

      assert_push_event view, "chat:event", %{
        type: "chat.message",
        message_id: assistant_id,
        message: %{role: "assistant", status: "streaming"},
        runtime: %{active: true},
        admission: %{canSubmit: false}
      }

      send(request_pid, {:respond, 200, chat_stream_response("Hello world!")})

      assert_push_event view, "chat:event", %{
        type: "chat.delta",
        message_id: ^assistant_id,
        sequence: 2,
        text: "Hello world!"
      }

      assert_push_event view, "chat:event", %{
        type: "chat.message",
        message_id: ^assistant_id,
        sequence: 3,
        message: %{content: "Hello world!", status: "complete"},
        runtime: %{active: false},
        admission: %{canSubmit: true}
      }

      render_hook(view, "chat.sync", chat_params(provider))

      assert_push_event view, "chat:event", %{
        type: "chat.snapshot",
        sequences: %{^assistant_id => 3},
        messages: [%{role: "user"}, %{id: ^assistant_id, content: "Hello world!"}]
      }
    end

    test "provider admission deduplicates requests and rejects a second active send", %{
      conn: conn
    } do
      {provider, _bypass} = controlled_chat_provider(self())
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      render_hook(view, "toggle_chat", %{})
      params = chat_params(provider, %{"text" => "hello"})
      render_hook(view, "chat.send", params)
      assert_reply view, %{status: "ok"}
      assert_receive {:provider_request, request_pid}, 1_000

      render_hook(view, "chat.send", params)
      assert_reply view, %{status: "ok"}
      render_hook(view, "chat.send", chat_params(provider, %{"text" => "second"}))
      assert_reply view, %{status: "error", message: "Wait for the provider response"}
      refute_receive {:provider_request, _}, 100

      render_hook(view, "chat.stop", chat_params(provider))
      assert_reply view, %{status: "ok"}
      send(request_pid, :release)
      send(view.pid, {:provider_chunk, {:text_delta, "stale"}})
      send(view.pid, :provider_done)
      render_hook(view, "chat.sync", chat_params(provider))

      assert_push_event view, "chat:event", %{
        type: "chat.snapshot",
        runtime: %{active: false},
        messages: [%{role: "user"}, %{role: "assistant", status: "cancelled", content: ""}]
      }
    end

    test "provider errors have stable IDs and Clear cancels an admitted stream", %{conn: conn} do
      {provider, _bypass} = controlled_chat_provider(self())
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      render_hook(view, "toggle_chat", %{})
      render_hook(view, "chat.send", chat_params(provider, %{"text" => "hello"}))
      assert_reply view, %{status: "ok"}
      assert_receive {:provider_request, request_pid}, 1_000
      send(request_pid, {:respond, 401, Jason.encode!(%{error: %{message: "Invalid API key"}})})

      assert_push_event view, "chat:event", %{
        type: "chat.snapshot",
        messages: [
          %{role: "user"},
          %{id: error_id, role: "error", status: "error", content: error}
        ]
      }

      assert is_binary(error_id)
      assert error =~ "Error:"

      render_hook(view, "chat_clear", %{})
      assert_push_event view, "chat:event", %{type: "chat.snapshot", messages: []}
      render_hook(view, "chat.send", chat_params(provider, %{"text" => "second"}))
      assert_reply view, %{status: "ok"}
      assert_receive {:provider_request, next_request_pid}, 1_000
      render_hook(view, "chat_clear", %{})
      send(next_request_pid, :release)
      send(view.pid, {:provider_chunk, {:text_delta, "stale"}})
      send(view.pid, :provider_done)
      render_hook(view, "chat.sync", chat_params(provider))

      assert_push_event view, "chat:event", %{
        type: "chat.snapshot",
        messages: [],
        runtime: %{active: false}
      }
    end
  end

  defp chat_params(provider, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "provider-chat-#{provider.id}",
        "conversation_id" => provider.id,
        "request_id" => Ecto.UUID.generate()
      },
      attrs
    )
  end

  defp controlled_chat_provider(test_pid) do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      Process.flag(:trap_exit, true)
      send(test_pid, {:provider_request, self()})

      receive do
        :release ->
          conn

        {:respond, status, body} ->
          conn
          |> Plug.Conn.put_resp_content_type(
            if(status == 200, do: "text/event-stream", else: "application/json")
          )
          |> Plug.Conn.send_resp(status, body)
      after
        5_000 -> Plug.Conn.send_resp(conn, 500, "test stream response missing")
      end
    end)

    provider =
      create_provider!(%{
        name: "react-chat",
        type: "openai",
        base_url: "http://localhost:#{bypass.port}",
        config: %{"available_models" => [%{"id" => "test-model", "name" => "Test Model"}]}
      })

    {provider, bypass}
  end

  defp chat_stream_response(text) do
    "data: " <>
      Jason.encode!(%{choices: [%{index: 0, delta: %{content: text}}]}) <>
      "\n\ndata: " <>
      Jason.encode!(%{choices: [%{index: 0, delta: %{}, finish_reason: "stop"}]}) <>
      "\n\ndata: [DONE]\n\n"
  end

  defp create_provider!(attrs) do
    attrs = Map.update!(attrs, :name, &"#{&1}-#{Ecto.UUID.generate()}")
    {:ok, provider} = Synapsis.Providers.create(attrs)
    on_exit(fn -> Synapsis.Providers.delete(provider.id) end)
    provider
  end
end
