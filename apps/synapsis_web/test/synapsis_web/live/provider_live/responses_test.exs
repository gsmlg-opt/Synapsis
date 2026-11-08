defmodule SynapsisWeb.ProviderLive.ResponsesTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Models, Providers}
  alias Synapsis.Provider.{Adapter, Registry}

  @model "responses-fixture-model"
  @secret "responses-fixture-credential"

  for suffix <- ["", "/v1/"] do
    test "explicit Responses creation discovers suggestions at #{inspect(suffix)} and survives reload",
         %{
           conn: conn
         } do
      fixture = Gaoxy.Test.open()
      owner = self()
      credential = credential!()
      name = "responses-#{Ecto.UUID.generate()}"
      base_url = String.trim_trailing(Gaoxy.Test.url(fixture), "/") <> unquote(suffix)

      Gaoxy.Test.expect_once(fixture, "GET", "/v1/models", fn conn ->
        assert get_req_header(conn, "authorization") == ["Bearer " <> @secret]
        send(owner, :models_discovered)
        send_json(conn, %{"data" => [%{"id" => @model}]})
      end)

      {:ok, view, html} = live(conn, ~p"/settings/providers/new")
      assert html =~ "OpenAI Responses"

      view
      |> element(~s(button[phx-click="select_custom"][phx-value-type="openai_responses"]))
      |> render_click()

      react_form_submit(view, "create-provider-form", %{
        "name" => name,
        "base_url" => base_url,
        "credential_id" => credential.id
      })

      flash = assert_redirected(view, ~p"/settings/providers")

      assert flash["info"] ==
               "Provider created; model suggestions loaded. Import models in Manage Models."

      assert_receive :models_discovered
      assert {:ok, provider} = Providers.get_by_name(name)
      cleanup_provider(provider.id)
      assert provider.type == "openai_responses"
      assert provider.preset == nil
      assert provider.base_url == base_url
      assert provider.credential_id == credential.id
      assert provider.config["model_catalog_migrated"] == true
      assert [%{"id" => @model}] = provider.config["available_models"]
      assert {:ok, []} = Models.list(provider_id: provider.id)
      assert {:ok, Adapter} = Registry.module_for("openai_responses")
      assert {:ok, Adapter} = Registry.module_for(name)

      assert :ok = Store.reload(:provider)
      assert {:ok, reloaded} = Providers.get(provider.id)
      assert reloaded.type == provider.type
      assert reloaded.credential_id == credential.id
      assert reloaded.config == provider.config
      assert {:ok, config} = Providers.runtime_config(name)
      assert config.provider_id == provider.id
      assert config.type == "openai_responses"
    end
  end

  test "Responses detail preserves identities and streams test chat only after model import", %{
    conn: conn
  } do
    original = Gaoxy.Test.open()
    fixture = Gaoxy.Test.open()
    owner = self()
    credential = credential!()

    assert {:ok, provider} =
             Providers.create(%{
               name: "responses-detail-#{Ecto.UUID.generate()}",
               type: "openai_responses",
               base_url: Gaoxy.Test.url(original),
               credential_id: credential.id,
               config: %{
                 "model_catalog_migrated" => true,
                 "available_models" => [%{"id" => @model, "name" => "Fixture model"}]
               }
             })

    cleanup_provider(provider.id)

    Gaoxy.Test.stub(original, "POST", "/v1/responses", fn conn ->
      send(owner, :original_endpoint_called)
      send_resp(conn, 500, "unexpected")
    end)

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "openai_responses"
    refute html =~ @secret
    render_hook(view, "toggle_chat", %{})
    render_hook(view, "chat.send", chat_params(provider, "before import"))
    assert_reply(view, %{status: "error", message: "Model is currently unavailable."})
    refute_receive :original_endpoint_called

    assert {:ok, [model]} = Models.import(provider.id, [%{id: @model, name: "Fixture model"}])

    react_form_submit(view, "edit-provider-form", %{
      "base_url" => Gaoxy.Test.url(fixture, "/v1/"),
      "enabled" => true,
      "credential_id" => credential.id
    })

    assert {:ok, updated} = Providers.get(provider.id)
    assert updated.name == provider.name
    assert updated.type == "openai_responses"
    assert updated.credential_id == credential.id
    assert {:ok, retained_model} = Models.get(model.id)
    assert retained_model.provider_id == provider.id
    assert retained_model.model == @model

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer " <> @secret]
      {:ok, body, conn} = read_body(conn)
      send(owner, {:responses_request, Jason.decode!(body)})

      events = [
        %{"type" => "response.output_text.delta", "delta" => "Responses fixture reply"},
        %{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => []}
        }
      ]

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
    end)

    render_hook(view, "chat.send", chat_params(provider, "local fixture question"))
    assert_reply(view, %{status: "ok"})
    assert_receive {:responses_request, wire}, 1_000
    assert wire["model"] == @model
    assert wire["stream"] == true
    refute Map.has_key?(wire, "messages")

    assert [
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "before import"}]
             },
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "local fixture question"}]
             }
           ] =
             wire["input"]

    assert_push_event(view, "chat:event", %{
      type: "chat.message",
      message: %{role: "assistant", content: "Responses fixture reply", status: "complete"},
      runtime: %{active: false}
    })

    refute_receive :original_endpoint_called
  end

  test "Responses has an explicit default endpoint while existing OpenAI presets keep Chat", %{
    conn: conn
  } do
    assert Providers.default_base_url("openai_responses") == "https://api.openai.com"
    assert Adapter.resolve_transport_type("openai") == :openai

    {:ok, view, _} = live(conn, ~p"/settings/providers/new")
    html = render_hook(view, "select_custom", %{"type" => "openai"})
    assert html =~ "New OpenAI Compatible"

    for name <- ["openai", "openai-sub", "backplane"] do
      preset = Enum.find(Providers.preset_providers(), &(&1.name == name))
      assert preset.type == "openai"
    end
  end

  defp credential! do
    {:ok, credential} =
      Credentials.create(%{name: "Responses fixture #{Ecto.UUID.generate()}", key: @secret})

    on_exit(fn -> Credentials.delete(credential.id) end)
    credential
  end

  defp cleanup_provider(id) do
    on_exit(fn ->
      {:ok, models} = Models.list(provider_id: id)
      Enum.each(models, &Models.delete/1)
      Providers.delete(id)
    end)
  end

  defp send_json(conn, data),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(data))

  defp chat_params(provider, text),
    do: %{
      "id" => "provider-chat-#{provider.id}",
      "conversation_id" => provider.id,
      "request_id" => Ecto.UUID.generate(),
      "text" => text
    }
end
