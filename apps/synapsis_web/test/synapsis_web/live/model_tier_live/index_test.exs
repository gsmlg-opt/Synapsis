defmodule SynapsisWeb.ModelTierLive.IndexTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers
  alias Synapsis.{Config.Store, Models, Providers}

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

    react_form_submit(view, "model-form", %{
      "provider_id" => provider.id,
      "model" => "invalid",
      "context_window" => "0",
      "enabled" => true
    })

    assert render(view) =~ "must be greater than 0"
    assert {:error, :not_found} = Models.get_by_identity(provider.id, "invalid")
  end

  test "edits, disables and deletes configured records", %{conn: conn, provider: provider} do
    {:ok, model} =
      Models.create(%{provider_id: provider.id, model: "manual", context_window: 32768})

    {:ok, view, _} = live(conn, ~p"/settings/models")
    render_hook(view, "edit_model", %{"id" => model.id})

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
