defmodule SynapsisWeb.ModelTierLive.IndexTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers
  alias Synapsis.{Config.Store, Models, Providers}

  test "an open model catalog refreshes provider choices without importing discovery", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/settings/models")

    {:ok, provider} =
      Providers.create(%{
        name: "new-live-provider",
        type: "openai",
        config: %{
          "model_catalog_migrated" => true,
          "available_models" => [%{"id" => "discovered-only"}]
        }
      })

    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})

    assert has_element?(
             view,
             "[data-form-id='model-discovery-provider-form'] [data-dm-react-field*='#{provider.id}']"
           )

    assert {:error, :not_found} = Models.get_by_identity(provider.id, "discovered-only")
    assert {:ok, _} = Providers.delete(provider.id)
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})

    refute has_element?(
             view,
             "[data-form-id='model-discovery-provider-form'] [data-dm-react-field*='#{provider.id}']"
           )
  end

  test "provider changes preserve an unsaved model editor draft", %{
    conn: conn,
    provider: provider
  } do
    {:ok, view, _} = live(conn, ~p"/settings/models")
    render_click(element(view, "[phx-click='new_model']"))

    react_form_change(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "pending-model",
      "name" => "Pending name",
      "context_window" => 384_000
    })

    {:ok, other} =
      Providers.create(%{
        name: "draft-provider",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})
    assert has_element?(view, "[data-form-id='model-form'] [data-dm-react-field*='#{other.id}']")
    html = view |> element("[data-form-id='model-form']") |> render() |> LazyHTML.from_fragment()

    [initial] =
      html |> LazyHTML.query("[data-form-id]") |> LazyHTML.attribute("data-initial-values")

    values = Jason.decode!(initial)
    assert values["model"] == "pending-model"
    assert values["name"] == "Pending name"
    assert values["context_window"] == 384_000
    assert {:error, :not_found} = Models.get_by_identity(provider.id, "pending-model")
  end

  test "discovery selects a newly added provider after the previous one is deleted", %{
    conn: conn,
    provider: provider
  } do
    {:ok, view, _} = live(conn, ~p"/settings/models")
    react_form_change(view, "model-discovery-provider-form", %{"provider_id" => provider.id})
    assert {:ok, _} = Providers.delete(provider.id)
    Providers.notify_changed()
    refute has_element?(view, "[data-form-id='model-discovery-provider-form']")

    {:ok, replacement} =
      Providers.create(%{
        name: "replacement",
        type: "openai",
        config: %{
          "model_catalog_migrated" => true,
          "available_models" => [%{"id" => "replacement-model"}]
        }
      })

    Providers.notify_changed()
    assert has_element?(view, "[phx-click='import_model'][phx-value-model='replacement-model']")

    [values] =
      view
      |> element("[data-form-id='model-discovery-provider-form']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-initial-values]")
      |> LazyHTML.attribute("data-initial-values")

    assert Jason.decode!(values)["provider_id"] == replacement.id
    render_click(element(view, "[phx-click='import_model'][phx-value-model='replacement-model']"))
    assert {:ok, _} = Models.get_by_identity(replacement.id, "replacement-model")
  end

  test "an empty discovery provider recovery does not disconnect the page", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/models")

    render_hook(view, "select_provider", %{
      "id" => "model-discovery-provider-form",
      "values" => %{},
      "revision" => 1
    })

    assert has_element?(view, "[phx-click='refresh_models'][disabled]")
    refute has_element?(view, "[phx-click='import_model']")
    assert render(view) =~ "Models"
  end

  test "deleting a draft provider clears that field and retains the rest of the new model", %{
    conn: conn,
    provider: provider
  } do
    {:ok, replacement} =
      Providers.create(%{
        name: "replacement",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, view, _} = live(conn, ~p"/settings/models")
    render_click(element(view, "[phx-click='new_model']"))

    react_form_change(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "pending-model",
      "name" => "Pending name",
      "context_window" => 384_000
    })

    assert {:ok, _} = Providers.delete(provider.id)
    Providers.notify_changed()
    assert has_element?(view, "#model-modal [role='alert']", "Select a provider before saving")

    [json] =
      view
      |> element("[data-form-id='model-form']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-initial-values]")
      |> LazyHTML.attribute("data-initial-values")

    assert %{
             "provider_id" => "",
             "model" => "pending-model",
             "name" => "Pending name",
             "context_window" => 384_000
           } = Jason.decode!(json)

    react_form_submit(view, "model-form", %{"provider_id" => replacement.id})

    assert {:ok, %{context_window: 384_000}} =
             Models.get_by_identity(replacement.id, "pending-model")
  end

  test "discovery explains missing authorization and links to provider settings", %{
    conn: conn,
    provider: provider
  } do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      Plug.Conn.send_resp(conn, 401, "")
    end)

    {:ok, _} =
      Providers.update(provider.id, %{
        preset: "backplane",
        base_url: "http://localhost:#{bypass.port}/v1",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, view, _} = live(conn, ~p"/settings/models")
    refute has_element?(view, "[phx-click='import_model']")
    assert has_element?(view, "[phx-click='import_all_models'][disabled]")
    render_click(element(view, "[phx-click='refresh_models']"))
    html = render_async(view)
    assert html =~ "HTTP 401"
    assert html =~ "access token"
    assert has_element?(view, "a[href='/settings/providers/#{provider.id}']")
    assert {:ok, []} = Models.list(provider_id: provider.id)
  end

  setup do
    for type <- [:provider, :model, :agent], do: Synapsis.DataCase.clear_config_store(type)

    {:ok, provider} =
      Providers.create(%{
        name: "catalog-provider",
        type: "openai",
        config: %{
          "model_catalog_migrated" => true,
          "available_models" => [
            %{"id" => "suggested", "name" => "Suggested", "context_window" => 32768}
          ]
        }
      })

    {:ok, provider: provider}
  end

  test "creates a manual model with a required positive context window", %{
    conn: conn,
    provider: provider
  } do
    {:ok, view, _} = live(conn, ~p"/settings/models")
    assert has_element?(view, "h1", "Models")
    view |> element("[phx-click='new_model']") |> render_click()

    react_form_submit(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "manual",
      "name" => "Manual",
      "context_window" => "49152",
      "enabled" => true
    })

    assert render(view) =~ "Model saved"
    assert {:ok, model} = Models.get_by_identity(provider.id, "manual")
    assert model.context_window == 49152
    assert :ok = Store.reload(:model)
    assert {:ok, reloaded} = Models.get(model.id)
    assert reloaded.context_window == 49152

    view |> element("[phx-click='new_model']") |> render_click()

    react_form_submit(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "invalid",
      "context_window" => "0",
      "enabled" => true
    })

    assert render(view) =~ "must be greater than 0"
    assert {:error, :not_found} = Models.get_by_identity(provider.id, "invalid")
  end

  test "adds models in a modal with a 256k default and context presets", %{
    conn: conn,
    provider: provider
  } do
    {:ok, view, _} = live(conn, ~p"/settings/models")
    refute has_element?(view, "[data-form-id='model-form']")

    view |> element("[phx-click='new_model']") |> render_click()

    assert has_element?(
             view,
             "dialog#model-modal[phx-hook='MCPFormModal'][data-close-event='cancel_edit']"
           )

    assert has_element?(view, "#model-modal-title", "Add Model")
    assert has_element?(view, "#model-modal button[type='submit']", "Save Model")

    assert has_element?(
             view,
             "#model-modal select[name='context_window'] option[value='256000'][selected]",
             "256k"
           )

    for {value, label} <- [
          {384_000, "384k"},
          {500_000, "500k"},
          {768_000, "768k"},
          {1_000_000, "1M"}
        ] do
      assert has_element?(view, "#model-modal option[value='#{value}']", label)
    end

    react_form_submit(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "default-context"
    })

    assert {:ok, model} = Models.get_by_identity(provider.id, "default-context")
    assert model.context_window == 256_000
    refute has_element?(view, "#model-modal")
  end

  test "keeps invalid drafts open and clears them when the modal is cancelled", %{
    conn: conn,
    provider: provider
  } do
    {:ok, view, _} = live(conn, ~p"/settings/models")
    view |> element("[phx-click='new_model']") |> render_click()

    react_form_submit(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "invalid-draft",
      "context_window" => "0"
    })

    assert has_element?(view, "#model-modal [role='alert']", "must be greater than 0")
    assert render(view) =~ "invalid-draft"
    render_hook(view, "cancel_edit", %{"reason" => "escape"})
    refute has_element?(view, "#model-modal")
    view |> element("[phx-click='new_model']") |> render_click()
    refute has_element?(view, "#model-modal [role='alert']")
    refute render(view) =~ "invalid-draft"
    assert has_element?(view, "#model-modal option[value='256000'][selected]")
    view |> element("#model-modal [phx-click='cancel_edit']", "Cancel") |> render_click()
    refute has_element?(view, "#model-modal")
  end

  test "edits, disables and deletes configured records", %{conn: conn, provider: provider} do
    {:ok, model} =
      Models.create(%{provider_id: provider.id, model: "manual", context_window: 32768})

    {:ok, view, _} = live(conn, ~p"/settings/models")
    render_hook(view, "edit_model", %{"id" => model.id})
    assert has_element?(view, "#model-modal-title", "Edit Model")
    assert has_element?(view, "#model-modal option[value='32768'][selected]")

    react_form_submit(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "manual",
      "name" => "Edited",
      "context_window" => "8192",
      "enabled" => false
    })

    assert {:ok, edited} = Models.get(model.id)
    assert edited.context_window == 8192
    refute edited.enabled
    assert render(view) =~ "Edited"
    render_hook(view, "delete_model", %{"id" => model.id})
    assert {:error, :not_found} = Models.get(model.id)
  end

  test "bulk changes affect only selected models and persist after reload", %{
    conn: conn,
    provider: provider
  } do
    models =
      for name <- ["first", "second", "unselected"] do
        {:ok, model} =
          Models.create(%{provider_id: provider.id, model: name, context_window: 128_000})

        model
      end

    [first, second, unselected] = models
    {:ok, view, _} = live(conn, ~p"/settings/models")

    for model <- [first, second] do
      view
      |> element("input[phx-click='toggle_model'][phx-value-id='#{model.id}']")
      |> render_click()
    end

    assert has_element?(view, "#model-selection-count", "2 selected")

    assert has_element?(
             view,
             "[data-form-id='bulk-context-form'] button[type='submit']",
             "Apply to selected"
           )

    react_form_submit(view, "bulk-context-form", %{"context_window" => "768000"})
    view |> element("[phx-click='bulk_status'][phx-value-enabled='false']") |> render_click()
    assert :ok = Store.reload(:model)

    for model <- [first, second] do
      assert {:ok, updated} = Models.get(model.id)
      assert updated.context_window == 768_000
      refute updated.enabled
    end

    assert {:ok, ^unselected} = Models.get(unselected.id)

    view |> element("[phx-click='bulk_status'][phx-value-enabled='true']") |> render_click()
    assert {:ok, %{enabled: true}} = Models.get(first.id)
    view |> element("[phx-click='bulk_delete']") |> render_click()
    assert {:error, :not_found} = Models.get(first.id)
    assert {:error, :not_found} = Models.get(second.id)
    assert {:ok, ^unselected} = Models.get(unselected.id)
    assert has_element?(view, "#model-selection-count", "0 selected")
  end

  test "selects all, clears selection and rejects invalid bulk context without writes", %{
    conn: conn,
    provider: provider
  } do
    {:ok, model} =
      Models.create(%{provider_id: provider.id, model: "bulk", context_window: 128_000})

    {:ok, view, _} = live(conn, ~p"/settings/models")
    view |> element("input[phx-click='toggle_all_models']") |> render_click()
    assert has_element?(view, "input[phx-value-id='#{model.id}'][checked]")
    react_form_submit(view, "bulk-context-form", %{"context_window" => "0"})
    assert render(view) =~ "Select a context window preset"
    assert {:ok, ^model} = Models.get(model.id)
    view |> element("[phx-click='clear_selection']") |> render_click()
    refute has_element?(view, "input[phx-value-id='#{model.id}'][checked]")
    refute has_element?(view, "[data-form-id='bulk-context-form']")
    render_hook(view, "bulk_delete", %{})
    assert {:ok, ^model} = Models.get(model.id)
  end

  test "imports all suggestions while retaining existing model choices", %{
    conn: conn,
    provider: provider
  } do
    {:ok, _} =
      Providers.update(provider.id, %{
        config:
          Map.put(provider.config, "available_models", [
            %{"id" => "suggested", "context_window" => 384_000},
            %{"id" => "another", "context_window" => 500_000}
          ])
      })

    {:ok, existing} =
      Models.create(%{
        provider_id: provider.id,
        model: "suggested",
        context_window: 768_000,
        enabled: false
      })

    {:ok, view, _} = live(conn, ~p"/settings/models")
    view |> element("[phx-click='import_all_models']") |> render_click()
    assert {:ok, ^existing} = Models.get(existing.id)
    assert {:ok, %{context_window: 500_000}} = Models.get_by_identity(provider.id, "another")
  end

  test "imports discovery suggestions repeatedly without resetting user choices", %{
    conn: conn,
    provider: provider
  } do
    {:ok, view, _} = live(conn, ~p"/settings/models")
    render_hook(view, "select_provider", %{"provider_id" => provider.id})
    assert render(view) =~ "Suggested"
    render_hook(view, "import_model", %{"model" => "suggested"})
    assert {:ok, model} = Models.get_by_identity(provider.id, "suggested")
    assert {:ok, edited} = Models.update(model, %{context_window: 4096, enabled: false})
    render_hook(view, "import_model", %{"model" => "suggested"})
    assert {:ok, ^edited} = Models.get(model.id)
  end

  test "failed asynchronous discovery keeps configured models", %{conn: conn, provider: provider} do
    bypass = Bypass.open()
    Bypass.down(bypass)
    {:ok, _} = Providers.update(provider.id, %{base_url: "http://localhost:#{bypass.port}/v1"})

    {:ok, model} =
      Models.create(%{provider_id: provider.id, model: "manual", context_window: 4096})

    {:ok, view, _} = live(conn, ~p"/settings/models")
    render_hook(view, "select_provider", %{"provider_id" => provider.id})
    render_hook(view, "refresh_models", %{})
    html = render_async(view)
    assert html =~ "Failed to discover models"
    assert {:ok, ^model} = Models.get(model.id)
  end
end
