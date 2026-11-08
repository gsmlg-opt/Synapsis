defmodule Synapsis.Provider.DocumentModelsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Provider.DocumentModels
  alias Synapsis.{Config.Store, Models, ProviderConfig, Providers}

  setup do
    clear_config_store(:model)
    clear_config_store(:provider)

    on_exit(fn ->
      clear_config_store(:model)
      clear_config_store(:provider)
    end)

    :ok
  end

  test "pinned exact canonical profiles expose source PDF priorities, defaults and literal false hints" do
    anthropic = DocumentModels.metadata(%ProviderConfig{name: "anthropic", type: "anthropic"})
    assert anthropic.profile == "anthropic"
    assert anthropic.capabilities == ["image"]
    assert anthropic.auto_priority == %{"image" => 20}
    assert anthropic.default_models == %{"image" => "claude-opus-5-5"}
    assert anthropic.native_document_inputs == ["pdf"]
    google = DocumentModels.metadata(%ProviderConfig{name: "google", type: "google"})
    assert google.profile == "google"
    assert google.capabilities == ["image", "audio", "video"]
    assert google.auto_priority == %{"image" => 30, "audio" => 40, "video" => 10}
    assert google.default_models["image"] == "gemini-3-flash-preview"
    assert google.native_document_inputs == ["pdf"]
    openai = DocumentModels.metadata(%ProviderConfig{name: "openai", type: "openai"})
    assert openai.default_models["image"] == "gpt-6-astra"
    assert openai.auto_priority["image"] == 20
    minimax = DocumentModels.metadata(%ProviderConfig{name: "minimax", type: "anthropic"})

    assert minimax.document_models == %{
             "pdf" => %{"image" => false, "textExtraction" => "MiniMax-M2.7"}
           }

    assert minimax.default_models["image"] == "MiniMax-VL-01"
    assert minimax.auto_priority["image"] == 40
  end

  test "saved explicit profile precedes exact preset and canonical name while custom transport stays its own identity" do
    explicit = %ProviderConfig{
      name: "anthropic",
      type: "anthropic",
      preset: "minimax-cn",
      config: %{"media_understanding" => %{"profile" => "google"}}
    }

    assert DocumentModels.metadata(explicit).profile == "google"
    preset = %ProviderConfig{name: "private-account", type: "anthropic", preset: "minimax-cn"}
    assert DocumentModels.metadata(preset).profile == "minimax"

    custom =
      DocumentModels.metadata(%ProviderConfig{
        name: "my-anthropic-service",
        type: "anthropic",
        base_url: "http://localhost/anthropic"
      })

    assert custom.profile == nil
    assert custom.native_document_inputs == []
    assert custom.default_models == %{}
  end

  test "source-shaped overrides and absent versus false PDF hints survive provider TOML reload" do
    fixture = Gaoxy.Test.open()

    media = %{
      "profile" => "google",
      "capabilities" => ["image"],
      "autoPriority" => %{"image" => 7},
      "defaultModels" => %{"image" => "local-vision"},
      "nativeDocumentInputs" => [],
      "documentModels" => %{"pdf" => %{"image" => false, "textExtraction" => "local-text"}}
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: "document-override",
               type: "openai",
               base_url: Gaoxy.Test.url(fixture),
               api_key_encrypted: "ordinary-fixture",
               config: %{"media_understanding" => media}
             })

    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.config["media_understanding"] == media
    metadata = DocumentModels.metadata(reloaded)
    assert metadata.profile == "google"
    assert metadata.capabilities == ["image"]
    assert metadata.auto_priority["image"] == 7
    assert metadata.default_models["image"] == "local-vision"
    assert metadata.native_document_inputs == []
    assert metadata.document_models["pdf"]["image"] === false
    assert metadata.document_models["pdf"]["textExtraction"] == "local-text"

    assert {:ok, changed} =
             Providers.update(provider.id, %{
               config: %{"media_understanding" => %{"profile" => "google"}}
             })

    assert changed.id == provider.id
    assert :ok = Store.reload(:provider)
    assert {:ok, ordinary} = Providers.get(provider.id)
    assert DocumentModels.metadata(ordinary).native_document_inputs == ["pdf"]

    refute Map.has_key?(
             Map.get(DocumentModels.metadata(ordinary).document_models, "pdf", %{}),
             "image"
           )
  end

  test "document snapshot reads existing saved UUIDs without importing models or rewriting configuration" do
    fixture = Gaoxy.Test.open()

    assert {:ok, provider} =
             Providers.create(%{
               name: "snapshot-account",
               type: "openai",
               preset: "openai",
               base_url: Gaoxy.Test.url(fixture),
               api_key_encrypted: "ordinary-fixture"
             })

    assert {:ok, record} =
             Models.create(%{
               provider_id: provider.id,
               model: "gpt-4o",
               input: ["text", "image"],
               selection_order: 4
             })

    before =
      for type <- [:provider, :model], into: %{}, do: {type, File.read!(Store.file_path(type))}

    assert Providers.document_model_snapshot() != nil
    assert Providers.document_model_snapshot() != nil
    assert {:ok, ^record} = Models.get(record.id)
    assert {:ok, [^record]} = Models.list()
    assert {:ok, [same]} = Providers.list()
    assert same.id == provider.id

    assert for(
             type <- [:provider, :model],
             into: %{},
             do: {type, File.read!(Store.file_path(type))}
           ) == before
  end
end
