defmodule Synapsis.ModelMediaMetadataTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{Config.Store, Models}

  setup do
    clear_config_store(:model)
    clear_config_store(:provider)

    on_exit(fn ->
      clear_config_store(:model)
      clear_config_store(:provider)
    end)

    :ok
  end

  test "optional modality and selection metadata round-trip through real models TOML" do
    provider = provider_id()
    assert {:ok, unknown} = Models.create(%{provider_id: provider, model: "unknown"})
    assert Map.get(unknown, :input) == nil
    assert Map.get(unknown, :selection_order) == nil

    assert {:ok, known} =
             Models.create(%{
               provider_id: provider,
               model: "vision",
               input: ["text", "image"],
               selection_order: 7
             })

    assert known.input == ["text", "image"]
    assert known.selection_order == 7
    assert {:ok, edited} = Models.update(known, %{input: ["image", "text"], selection_order: 2})
    assert :ok = Store.reload(:model)
    assert {:ok, ^unknown} = Models.get(unknown.id)
    assert {:ok, ^edited} = Models.get(known.id)
    assert edited.id == known.id
    assert File.read!(Store.file_path(:model)) =~ "selection_order"
    assert File.read!(Store.file_path(:model)) =~ "input"
  end

  test "new imports retain supplied modalities and provider-local source order without changing picker order" do
    provider = provider_id()

    assert {:ok, [zulu, alpha, middle]} =
             Models.import(provider, [
               %{id: "zulu", input: ["text", "image"]},
               %{id: "alpha", input: ["text"]},
               %{id: "middle", input: ["image"]}
             ])

    assert :ok = Store.reload(:model)
    assert {:ok, ordered} = Models.ordered(provider_id: provider)
    assert Enum.map(ordered, & &1.id) == [zulu.id, alpha.id, middle.id]
    assert Enum.map(ordered, & &1.input) == [["text", "image"], ["text"], ["image"]]
    assert {:ok, picker} = Models.list(provider_id: provider)
    assert Enum.map(picker, & &1.model) == ["alpha", "middle", "zulu"]

    assert {:ok, [explicit]} =
             Models.import(provider, [%{id: "supplied", input: ["text"], selection_order: 23}])

    assert explicit.selection_order == 23
    assert :ok = Store.reload(:model)
    assert {:ok, ^explicit} = Models.get(explicit.id)
  end

  test "reimport preserves saved identity, choices and edited media metadata" do
    provider = provider_id()

    assert {:ok, [original]} =
             Models.import(provider, [
               %{id: "report", input: ["text", "image"], selection_order: 3}
             ])

    assert {:ok, chosen} =
             Models.update(original, %{
               name: "My report",
               context_window: 8192,
               enabled: false,
               input: ["text"],
               selection_order: 19
             })

    assert {:ok, [same]} =
             Models.import(provider, [
               %{
                 id: "report",
                 name: "Remote name",
                 context_window: 128_000,
                 enabled: true,
                 input: ["image"],
                 selection_order: 0
               }
             ])

    assert same == chosen
    assert :ok = Store.reload(:model)
    assert {:ok, ^chosen} = Models.get(original.id)
  end

  test "legacy unknown metadata keeps deterministic public identity order and provider UUIDs stay distinct" do
    first = provider_id("00000000-0000-4000-8000-000000000001")
    second = provider_id("00000000-0000-4000-8000-000000000002")
    assert {:ok, b} = Models.create(%{provider_id: first, model: "b"})
    assert {:ok, a} = Models.create(%{provider_id: first, model: "a"})
    assert {:ok, other} = Models.create(%{provider_id: second, model: "a"})
    assert {:ok, ordered} = Models.ordered()
    assert Enum.map(ordered, & &1.id) == [a.id, b.id, other.id]
    assert a.id != other.id
    assert a.provider_id != other.provider_id
    assert :ok = Store.reload(:model)
    assert {:ok, ^ordered} = Models.ordered()
  end

  defp provider_id(id \\ Ecto.UUID.generate()) do
    assert {:ok, _} = Store.put(:provider, %{"id" => id, "name" => "media-" <> id})
    id
  end
end
