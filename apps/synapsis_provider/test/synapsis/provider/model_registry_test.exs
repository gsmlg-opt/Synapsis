defmodule Synapsis.Provider.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ModelRegistry

  describe "get/1" do
    test "returns known Anthropic model" do
      assert {:ok, model} = ModelRegistry.get("claude-sonnet-4-20250514")
      assert model.name == "Claude Sonnet 4"
      assert model.provider == "anthropic"
      assert model.context_window == 200_000
      assert model.supports_tools == true
      assert model.supports_thinking == true
    end

    test "returns known OpenAI model" do
      assert {:ok, model} = ModelRegistry.get("gpt-4o")
      assert model.provider == "openai"
      assert model.supports_streaming == true
    end

    test "returns known Google model" do
      assert {:ok, model} = ModelRegistry.get("gemini-2.0-flash")
      assert model.provider == "google"
      assert model.context_window == 1_000_000
    end

    test "returns error for unknown model" do
      assert {:error, :unknown} = ModelRegistry.get("nonexistent-model")
    end
  end

  describe "list/1" do
    test "lists Anthropic models" do
      models = ModelRegistry.list(:anthropic)
      assert length(models) >= 3
      ids = Enum.map(models, & &1.id)
      assert "claude-sonnet-4-20250514" in ids
      assert "claude-opus-4-20250514" in ids
    end

    test "lists OpenAI models" do
      models = ModelRegistry.list(:openai)
      assert length(models) >= 2
      ids = Enum.map(models, & &1.id)
      assert "gpt-4o" in ids
    end

    test "lists Google models" do
      models = ModelRegistry.list(:google)
      assert length(models) >= 3
      ids = Enum.map(models, & &1.id)
      assert "gemini-2.0-flash" in ids
    end

    test "accepts string provider names" do
      assert ModelRegistry.list("anthropic") == ModelRegistry.list(:anthropic)
    end

    test "returns empty for unknown provider" do
      assert [] = ModelRegistry.list(:unknown)
    end
  end

  describe "list_all/0" do
    test "returns all models across providers" do
      all = ModelRegistry.list_all()
      providers = all |> Enum.map(& &1.provider) |> Enum.uniq() |> Enum.sort()
      assert providers == ["anthropic", "google", "openai"]
    end
  end
end
