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

  test "module_for returns correct modules" do
    assert {:ok, Synapsis.Provider.Anthropic} = Registry.module_for("anthropic")
    assert {:ok, Synapsis.Provider.OpenAICompat} = Registry.module_for("openai")
    assert {:ok, Synapsis.Provider.Google} = Registry.module_for("google")
    assert {:ok, Synapsis.Provider.OpenAICompat} = Registry.module_for("local")
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
end
