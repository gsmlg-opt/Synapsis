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
end
