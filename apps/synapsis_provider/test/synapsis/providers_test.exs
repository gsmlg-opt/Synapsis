defmodule Synapsis.ProvidersTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Providers, ProviderConfig}
  alias Synapsis.Provider.Registry, as: ProviderRegistry

  @valid_attrs %{
    name: "test-provider",
    type: "anthropic",
    api_key_encrypted: "sk-ant-test",
    enabled: true
  }

  describe "create/1" do
    test "creates provider and syncs to registry" do
      assert {:ok, %ProviderConfig{} = provider} = Providers.create(@valid_attrs)
      assert provider.name == "test-provider"
      assert provider.type == "anthropic"
      assert provider.api_key_encrypted == "sk-ant-test"

      # Verify synced to ETS
      assert {:ok, config} = ProviderRegistry.get("test-provider")
      assert config.api_key == "sk-ant-test"
      assert config.type == "anthropic"
    end

    test "returns error for invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Providers.create(%{name: "", type: ""})
    end

    test "returns error for duplicate name" do
      {:ok, _} = Providers.create(@valid_attrs)
      assert {:error, %Ecto.Changeset{}} = Providers.create(@valid_attrs)
    end
  end

  describe "get/1" do
    test "returns provider by id" do
      {:ok, provider} = Providers.create(@valid_attrs)
      assert {:ok, fetched} = Providers.get(provider.id)
      assert fetched.name == "test-provider"
    end

    test "returns error for missing id" do
      assert {:error, :not_found} = Providers.get(Ecto.UUID.generate())
    end
  end

  describe "get_by_name/1" do
    test "returns provider by name" do
      {:ok, _} = Providers.create(@valid_attrs)
      assert {:ok, fetched} = Providers.get_by_name("test-provider")
      assert fetched.type == "anthropic"
    end

    test "returns error for missing name" do
      assert {:error, :not_found} = Providers.get_by_name("nonexistent")
    end
  end

  describe "list/1" do
    test "lists all providers" do
      {:ok, initial} = Providers.list()
      initial_count = length(initial)

      {:ok, _} = Providers.create(@valid_attrs)
      {:ok, _} = Providers.create(%{@valid_attrs | name: "other-provider", type: "google"})

      {:ok, providers} = Providers.list()
      assert length(providers) == initial_count + 2
    end

    test "filters by enabled" do
      {:ok, initial_enabled} = Providers.list(enabled: true)
      {:ok, initial_disabled} = Providers.list(enabled: false)

      {:ok, _} = Providers.create(@valid_attrs)
      {:ok, _} = Providers.create(%{@valid_attrs | name: "disabled-one", enabled: false})

      {:ok, enabled} = Providers.list(enabled: true)
      assert length(enabled) == length(initial_enabled) + 1
      assert Enum.any?(enabled, &(&1.name == "test-provider"))

      {:ok, disabled} = Providers.list(enabled: false)
      assert length(disabled) == length(initial_disabled) + 1
      assert Enum.any?(disabled, &(&1.name == "disabled-one"))
    end

    test "returns providers as list" do
      {:ok, providers} = Providers.list()
      assert is_list(providers)
    end
  end

  describe "update/2" do
    test "updates provider and syncs registry" do
      {:ok, provider} = Providers.create(@valid_attrs)

      assert {:ok, updated} = Providers.update(provider.id, %{base_url: "https://custom.api.com"})
      assert updated.base_url == "https://custom.api.com"

      # Verify registry is updated
      {:ok, config} = ProviderRegistry.get("test-provider")
      assert config.base_url == "https://custom.api.com"
    end

    test "disabling provider unregisters from registry" do
      {:ok, provider} = Providers.create(@valid_attrs)
      assert {:ok, _} = ProviderRegistry.get("test-provider")

      {:ok, _} = Providers.update(provider.id, %{enabled: false})
      assert {:error, :not_found} = ProviderRegistry.get("test-provider")
    end

    test "returns error for missing provider" do
      assert {:error, :not_found} = Providers.update(Ecto.UUID.generate(), %{enabled: false})
    end

    test "returns changeset error for invalid update" do
      {:ok, provider} = Providers.create(@valid_attrs)
      assert {:error, %Ecto.Changeset{}} = Providers.update(provider.id, %{type: "invalid"})
    end
  end

  describe "delete/1" do
    test "deletes provider and unregisters from registry" do
      {:ok, provider} = Providers.create(@valid_attrs)
      assert {:ok, _} = ProviderRegistry.get("test-provider")

      assert {:ok, _} = Providers.delete(provider.id)
      assert {:error, :not_found} = Providers.get(provider.id)
      assert {:error, :not_found} = ProviderRegistry.get("test-provider")
    end

    test "returns error for missing provider" do
      assert {:error, :not_found} = Providers.delete(Ecto.UUID.generate())
    end
  end

  describe "authenticate/2" do
    test "updates api key" do
      {:ok, provider} = Providers.create(Map.delete(@valid_attrs, :api_key_encrypted))
      assert is_nil(provider.api_key_encrypted)

      {:ok, updated} = Providers.authenticate(provider.id, "new-api-key")
      assert updated.api_key_encrypted == "new-api-key"
    end
  end

  describe "load_all_into_registry/0" do
    test "loads enabled providers into registry" do
      {:ok, _} = Providers.create(@valid_attrs)
      {:ok, _} = Providers.create(%{@valid_attrs | name: "disabled-one", enabled: false})

      # Clear registry
      ProviderRegistry.unregister("test-provider")
      ProviderRegistry.unregister("disabled-one")

      Providers.load_all_into_registry()

      assert {:ok, _} = ProviderRegistry.get("test-provider")
      assert {:error, :not_found} = ProviderRegistry.get("disabled-one")
    end
  end
end
