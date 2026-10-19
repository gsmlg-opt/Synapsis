defmodule Synapsis.ModelsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{Config.Store, Models}

  setup do
    clear_config_store(:model)
    :ok
  end

  test "catalog records round-trip through models.toml with stable identity" do
    provider_id = Ecto.UUID.generate()

    assert {:ok, model} =
             Models.create(%{provider_id: provider_id, model: "manual", context_window: 32_768})

    assert {:ok, edited} = Models.update(model, %{context_window: 65_536, enabled: false})
    assert :ok = Store.reload(:model)
    assert {:ok, reloaded} = Models.get(model.id)
    assert reloaded == edited
    assert reloaded.context_window == 65_536
    refute reloaded.enabled
    assert File.read!(Store.file_path(:model)) =~ "[[models]]"
    assert {:ok, _} = Models.delete(model.id)
    assert {:error, :not_found} = Models.get(model.id)
  end

  test "updates keep the stable catalog ID" do
    {:ok, model} =
      Models.create(%{provider_id: Ecto.UUID.generate(), model: "original", context_window: 4096})

    assert {:ok, updated} = Models.update(model, %{id: Ecto.UUID.generate(), model: "renamed"})
    assert updated.id == model.id
    assert {:ok, [^updated]} = Models.list()
  end

  test "requires a provider, raw model ID and a positive token window" do
    for context <- [nil, 0, -1, "invalid"] do
      assert {:error, %Ecto.Changeset{}} =
               Models.create(%{
                 provider_id: Ecto.UUID.generate(),
                 model: "manual",
                 context_window: context
               })
    end

    assert {:error, %Ecto.Changeset{}} = Models.create(%{context_window: 1024})
  end

  test "raw model IDs are unique within a provider and independent across providers" do
    attrs = %{provider_id: Ecto.UUID.generate(), model: "shared", context_window: 4096}
    assert {:ok, _} = Models.create(attrs)
    assert {:error, changeset} = Models.create(attrs)
    assert %{model: ["has already been taken for this provider"]} = errors_on(changeset)
    assert {:ok, _} = Models.create(%{attrs | provider_id: Ecto.UUID.generate()})
  end

  test "typed store rejects invalid raw models and duplicate provider/model identities" do
    provider_id = Ecto.UUID.generate()

    attrs = %{
      "id" => Ecto.UUID.generate(),
      "provider_id" => provider_id,
      "model" => "raw",
      "context_window" => 4096,
      "enabled" => true
    }

    assert {:error, _} = Store.put(:model, Map.put(attrs, "context_window", 0))
    assert {:ok, _} = Store.put(:model, attrs)
    assert {:error, _} = Store.put(:model, Map.put(attrs, "id", Ecto.UUID.generate()))
    assert {:ok, [_]} = Models.list()
  end

  test "repeated import preserves context, disabled state, display name and IDs" do
    provider_id = Ecto.UUID.generate()
    candidates = [%{id: "remote", name: "Remote", context_window: 32_768}]
    assert {:ok, [model]} = Models.import(provider_id, candidates)

    assert {:ok, edited} =
             Models.update(model, %{name: "My model", context_window: 8192, enabled: false})

    assert {:ok, [same]} =
             Models.import(provider_id, [
               %{id: "remote", name: "Changed", context_window: 128_000}
             ])

    assert same == edited
    assert {:ok, [^same]} = Models.list(provider_id: provider_id)
  end
end
