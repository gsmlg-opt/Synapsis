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

    test "all models have required fields" do
      for model <- ModelRegistry.list_all() do
        assert is_binary(model.id)
        assert is_binary(model.name)
        assert is_binary(model.provider)
        assert is_integer(model.context_window)
        assert model.context_window > 0
        assert is_boolean(model.supports_tools)
        assert is_boolean(model.supports_streaming)
      end
    end

    test "all model IDs are unique" do
      all = ModelRegistry.list_all()
      ids = Enum.map(all, & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "get/1 edge cases" do
    test "returns error for empty string" do
      assert {:error, :unknown} = ModelRegistry.get("")
    end

    test "returns error for nil" do
      assert {:error, :unknown} = ModelRegistry.get(nil)
    end

    test "Claude Opus has expected capabilities" do
      assert {:ok, model} = ModelRegistry.get("claude-opus-4-20250514")
      assert model.supports_tools == true
      assert model.context_window == 200_000
    end
  end
end
