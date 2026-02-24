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

    test "returns error for missing provider" do
      assert {:error, :not_found} = Providers.authenticate(Ecto.UUID.generate(), "new-key")
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

  describe "models/1" do
    test "returns static models for anthropic provider" do
      {:ok, provider} = Providers.create(%{@valid_attrs | name: "models-test-provider"})
      assert {:ok, models} = Providers.models(provider.id)
      assert is_list(models)
      assert length(models) > 0
    end

    test "returns error for unknown provider id" do
      assert {:error, :not_found} = Providers.models(Ecto.UUID.generate())
    end
  end

  describe "test_connection/1" do
    test "returns ok status with models_count for anthropic provider" do
      {:ok, provider} = Providers.create(%{@valid_attrs | name: "tc-test-provider"})
      assert {:ok, %{status: :ok, models_count: count}} = Providers.test_connection(provider.id)
      assert count > 0
    end

    test "returns error for unknown provider id" do
      assert {:error, :not_found} = Providers.test_connection(Ecto.UUID.generate())
    end
  end

  describe "build_runtime_config/1 (via create + registry)" do
    test "config with known atom keys are atomized safely" do
      # base_url is a known atom — should be present in runtime config as atom key
      {:ok, _provider} =
        Providers.create(%{
          @valid_attrs
          | name: "atom-test-provider"
        })

      {:ok, config} = ProviderRegistry.get("atom-test-provider")
      assert Map.has_key?(config, :api_key)
      assert Map.has_key?(config, :type)
      assert config.type == "anthropic"
    end

    test "uses correct default base_url for openai_compat type when none set" do
      {:ok, _} =
        Providers.create(%{
          name: "openai-compat-default-url-test",
          type: "openai_compat",
          api_key_encrypted: "sk-test",
          enabled: true
        })

      {:ok, config} = ProviderRegistry.get("openai-compat-default-url-test")
      assert config.base_url == "https://api.openai.com"
    end

    test "config with unknown string keys does not raise" do
      # Provider.config JSONB field with an unknown key — safe_to_atom uses to_existing_atom
      # so unknown atoms stay as strings rather than polluting the atom table
      {:ok, _provider} =
        Providers.create(%{
          name: "unknown-key-provider",
          type: "anthropic",
          api_key_encrypted: "sk-test",
          enabled: true,
          config: %{"unk_key_#{:rand.uniform(999_999_999)}" => "value"}
        })

      # The registry should be reachable and contain known atom keys
      {:ok, config} = ProviderRegistry.get("unknown-key-provider")
      assert is_map(config)
      assert Map.has_key?(config, :api_key)
      assert Map.has_key?(config, :type)
    end
  end

  describe "default_base_url/1" do
    test "returns correct URLs for all known providers" do
      assert Providers.default_base_url("anthropic") == "https://api.anthropic.com"
      assert Providers.default_base_url("openai") == "https://api.openai.com"
      assert Providers.default_base_url("openai_compat") == "https://api.openai.com"
      assert Providers.default_base_url("google") == "https://generativelanguage.googleapis.com"
      assert Providers.default_base_url("groq") == "https://api.groq.com/openai"
      assert Providers.default_base_url("deepseek") == "https://api.deepseek.com"
      assert Providers.default_base_url("openrouter") == "https://openrouter.ai/api"
      assert Providers.default_base_url("local") == "http://localhost:11434"
    end

    test "returns nil for unknown provider" do
      assert is_nil(Providers.default_base_url("unknown"))
      assert is_nil(Providers.default_base_url(""))
    end
  end

  describe "default_model/1" do
    test "returns correct models for known providers" do
      assert Providers.default_model("anthropic") == "claude-sonnet-4-6"
      assert Providers.default_model("openai") == "gpt-4.1"
      assert Providers.default_model("google") == "gemini-2.5-flash"
    end

    test "returns anthropic default for unknown provider" do
      assert Providers.default_model("unknown") == "claude-sonnet-4-6"
      assert Providers.default_model("local") == "claude-sonnet-4-6"
    end
  end

  describe "env_var_name/1" do
    test "returns correct env var names for known providers" do
      assert Providers.env_var_name("anthropic") == "ANTHROPIC_API_KEY"
      assert Providers.env_var_name("openai") == "OPENAI_API_KEY"
      assert Providers.env_var_name("google") == "GOOGLE_API_KEY"
    end

    test "returns nil for unknown provider" do
      assert is_nil(Providers.env_var_name("unknown"))
      assert is_nil(Providers.env_var_name("local"))
    end

    test "returns nil for empty string" do
      assert is_nil(Providers.env_var_name(""))
    end

    test "returns nil for providers without dedicated env vars" do
      assert is_nil(Providers.env_var_name("groq"))
      assert is_nil(Providers.env_var_name("deepseek"))
      assert is_nil(Providers.env_var_name("openrouter"))
      assert is_nil(Providers.env_var_name("openai_compat"))
    end
  end

  describe "list/1 ordering" do
    test "returns providers ordered by name ascending" do
      {:ok, _} = Providers.create(%{@valid_attrs | name: "zulu-provider"})
      {:ok, _} = Providers.create(%{@valid_attrs | name: "alpha-provider", type: "openai"})
      {:ok, _} = Providers.create(%{@valid_attrs | name: "mike-provider", type: "google"})

      {:ok, providers} = Providers.list()
      names = Enum.map(providers, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "create/1 with disabled provider" do
    test "disabled provider is not synced to registry" do
      {:ok, provider} =
        Providers.create(%{@valid_attrs | name: "disabled-at-create", enabled: false})

      assert provider.enabled == false
      assert {:error, :not_found} = ProviderRegistry.get("disabled-at-create")
    end
  end

  describe "create/1 with custom base_url" do
    test "custom base_url overrides default in registry config" do
      {:ok, _} =
        Providers.create(%{
          name: "custom-url-provider",
          type: "anthropic",
          api_key_encrypted: "sk-test",
          enabled: true,
          base_url: "https://custom.example.com"
        })

      {:ok, config} = ProviderRegistry.get("custom-url-provider")
      assert config.base_url == "https://custom.example.com"
    end

    test "nil base_url uses default for provider type" do
      {:ok, _} =
        Providers.create(%{
          name: "nil-url-provider",
          type: "google",
          api_key_encrypted: "key",
          enabled: true,
          base_url: nil
        })

      {:ok, config} = ProviderRegistry.get("nil-url-provider")
      assert config.base_url == "https://generativelanguage.googleapis.com"
    end
  end

  describe "update/2 re-enabling provider" do
    test "re-enabling provider syncs it back to registry" do
      {:ok, provider} =
        Providers.create(%{@valid_attrs | name: "reenable-provider", enabled: false})

      assert {:error, :not_found} = ProviderRegistry.get("reenable-provider")

      {:ok, _} = Providers.update(provider.id, %{enabled: true})
      assert {:ok, config} = ProviderRegistry.get("reenable-provider")
      assert config.type == "anthropic"
    end
  end

  describe "authenticate/2 registry sync" do
    test "updates api key in registry" do
      {:ok, provider} = Providers.create(%{@valid_attrs | name: "auth-sync-provider"})
      {:ok, config_before} = ProviderRegistry.get("auth-sync-provider")
      assert config_before.api_key == "sk-ant-test"

      {:ok, _} = Providers.authenticate(provider.id, "new-secret-key")
      {:ok, config_after} = ProviderRegistry.get("auth-sync-provider")
      assert config_after.api_key == "new-secret-key"
    end
  end

  describe "default_base_url/1 edge cases" do
    test "returns nil for nil input" do
      assert is_nil(Providers.default_base_url(nil))
    end

    test "returns nil for empty string" do
      assert is_nil(Providers.default_base_url(""))
    end

    test "is case-sensitive" do
      assert is_nil(Providers.default_base_url("Anthropic"))
      assert is_nil(Providers.default_base_url("OPENAI"))
    end
  end

  describe "default_model/1 edge cases" do
    test "returns fallback for nil input" do
      assert Providers.default_model(nil) == "claude-sonnet-4-6"
    end

    test "returns fallback for empty string" do
      assert Providers.default_model("") == "claude-sonnet-4-6"
    end

    test "returns fallback for providers without specific default" do
      assert Providers.default_model("groq") == "claude-sonnet-4-6"
      assert Providers.default_model("deepseek") == "claude-sonnet-4-6"
    end

    test "returns openrouter default model" do
      assert Providers.default_model("openrouter") == "openai/gpt-4o"
    end

    test "returns openai_compat default model" do
      assert Providers.default_model("openai_compat") == "gpt-4o"
    end
  end
end
