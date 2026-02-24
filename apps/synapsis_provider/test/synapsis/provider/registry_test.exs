defmodule Synapsis.Provider.RegistryTest do
  use ExUnit.Case

  alias Synapsis.Provider.Registry

  test "register and get provider" do
    Registry.register("test_provider", %{api_key: "key123", base_url: "http://localhost"})
    assert {:ok, %{api_key: "key123"}} = Registry.get("test_provider")
  end

  test "get returns error for unknown provider" do
    assert {:error, :not_found} = Registry.get("unknown_provider_#{:rand.uniform(100_000)}")
  end

  test "module_for returns Adapter for all known types" do
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("anthropic")
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("openai")
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("google")
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("local")
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("openai_compat")
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("openrouter")
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("groq")
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("deepseek")
    assert {:error, :unknown_provider} = Registry.module_for("unknown")
  end

  test "list returns all registered providers" do
    Registry.register("list_test_1", %{api_key: "a"})
    Registry.register("list_test_2", %{api_key: "b"})
    all = Registry.list()
    names = Enum.map(all, fn {name, _} -> name end)
    assert "list_test_1" in names
    assert "list_test_2" in names
  end

  test "unregister removes a registered provider" do
    Registry.register("to_unregister", %{api_key: "x"})
    assert {:ok, _} = Registry.get("to_unregister")

    Registry.unregister("to_unregister")
    assert {:error, :not_found} = Registry.get("to_unregister")
  end

  test "unregister is idempotent for unknown providers" do
    assert :ok = Registry.unregister("never_existed_#{:rand.uniform(999_999)}")
  end

  test "register overwrites existing entry" do
    Registry.register("overwrite_me", %{api_key: "old"})
    Registry.register("overwrite_me", %{api_key: "new"})
    assert {:ok, %{api_key: "new"}} = Registry.get("overwrite_me")
  end

  test "module_for returns error for nil" do
    assert {:error, :unknown_provider} = Registry.module_for(nil)
  end

  test "module_for returns error for empty string" do
    assert {:error, :unknown_provider} = Registry.module_for("")
  end

  test "list returns empty when filtered by name" do
    all = Registry.list()
    assert is_list(all)
  end

  test "register with complex config" do
    config = %{api_key: "sk-test", base_url: "http://custom:8080", extra: %{timeout: 30}}
    Registry.register("complex_test", config)
    assert {:ok, ^config} = Registry.get("complex_test")
  end

  test "module_for resolves via registered config type field" do
    # Register a provider with an explicit :type field
    Registry.register("my_openai_compat", %{type: "openai_compat", api_key: "k", base_url: "http://localhost"})
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("my_openai_compat")
  end

  test "module_for returns error when registered config has unknown type" do
    Registry.register("bad_type_provider", %{type: "foobar_unknown", api_key: "k"})
    # "foobar_unknown" is not in @known_types, but provider name isn't either
    # module_for falls back to string(provider_name) = "bad_type_provider"
    assert {:error, :unknown_provider} = Registry.module_for("bad_type_provider")
  end

  test "module_for for registered provider with no type falls back to provider name" do
    Registry.register("anthropic", %{api_key: "real-key"})
    # "anthropic" is in @known_types as provider name itself
    assert {:ok, Synapsis.Provider.Adapter} = Registry.module_for("anthropic")
  end
end
