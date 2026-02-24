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

    test "returns error for partial model id match" do
      assert {:error, :unknown} = ModelRegistry.get("claude")
      assert {:error, :unknown} = ModelRegistry.get("gpt")
      assert {:error, :unknown} = ModelRegistry.get("gemini")
    end

    test "returns error for model id with extra whitespace" do
      assert {:error, :unknown} = ModelRegistry.get(" gpt-4o ")
      assert {:error, :unknown} = ModelRegistry.get("gpt-4o\n")
    end
  end

  describe "get/1 specific model metadata" do
    test "Claude Sonnet 4.6 has expected capabilities" do
      assert {:ok, model} = ModelRegistry.get("claude-sonnet-4-6")
      assert model.name == "Claude Sonnet 4.6"
      assert model.provider == "anthropic"
      assert model.context_window == 200_000
      assert model.supports_tools == true
      assert model.supports_thinking == true
      assert model.max_output_tokens == 64_000
    end

    test "Claude Opus 4.6 has expected capabilities" do
      assert {:ok, model} = ModelRegistry.get("claude-opus-4-6")
      assert model.name == "Claude Opus 4.6"
      assert model.provider == "anthropic"
      assert model.context_window == 200_000
      assert model.supports_tools == true
      assert model.supports_thinking == true
    end

    test "GPT-4.1 has large context window" do
      assert {:ok, model} = ModelRegistry.get("gpt-4.1")
      assert model.name == "GPT-4.1"
      assert model.provider == "openai"
      assert model.context_window == 1_047_576
      assert model.supports_images == true
    end

    test "GPT-4.1 Mini has large context window" do
      assert {:ok, model} = ModelRegistry.get("gpt-4.1-mini")
      assert model.name == "GPT-4.1 Mini"
      assert model.provider == "openai"
      assert model.context_window == 1_047_576
    end

    test "Claude 3.5 Haiku does not support thinking" do
      assert {:ok, model} = ModelRegistry.get("claude-haiku-3-5-20241022")
      assert model.name == "Claude 3.5 Haiku"
      assert model.supports_thinking == false
      assert model.supports_images == true
      assert model.max_output_tokens == 8192
    end

    test "Claude Sonnet 4 has high max output tokens" do
      assert {:ok, model} = ModelRegistry.get("claude-sonnet-4-20250514")
      assert model.max_output_tokens == 64_000
    end

    test "Claude Opus 4 has lower max output tokens than Sonnet 4" do
      assert {:ok, opus} = ModelRegistry.get("claude-opus-4-20250514")
      assert {:ok, sonnet} = ModelRegistry.get("claude-sonnet-4-20250514")
      assert opus.max_output_tokens < sonnet.max_output_tokens
    end

    test "GPT-4o Mini metadata" do
      assert {:ok, model} = ModelRegistry.get("gpt-4o-mini")
      assert model.name == "GPT-4o Mini"
      assert model.provider == "openai"
      assert model.context_window == 128_000
      assert model.supports_thinking == false
    end

    test "o3 model supports thinking" do
      assert {:ok, model} = ModelRegistry.get("o3")
      assert model.name == "o3"
      assert model.provider == "openai"
      assert model.context_window == 200_000
      assert model.max_output_tokens == 100_000
      assert model.supports_thinking == true
    end

    test "o4-mini model supports thinking" do
      assert {:ok, model} = ModelRegistry.get("o4-mini")
      assert model.name == "o4-mini"
      assert model.supports_thinking == true
      assert model.max_output_tokens == 100_000
    end

    test "Gemini 2.5 Pro has large context and supports thinking" do
      assert {:ok, model} = ModelRegistry.get("gemini-2.5-pro-preview-05-06")
      assert model.name == "Gemini 2.5 Pro Preview"
      assert model.context_window == 1_000_000
      assert model.max_output_tokens == 65_536
      assert model.supports_thinking == true
    end

    test "Gemini 2.5 Pro GA model has large context and supports thinking" do
      assert {:ok, model} = ModelRegistry.get("gemini-2.5-pro")
      assert model.name == "Gemini 2.5 Pro"
      assert model.context_window == 1_000_000
      assert model.max_output_tokens == 65_536
      assert model.supports_thinking == true
    end

    test "Gemini 2.5 Flash supports thinking" do
      assert {:ok, model} = ModelRegistry.get("gemini-2.5-flash-preview-05-20")
      assert model.name == "Gemini 2.5 Flash Preview"
      assert model.supports_thinking == true
      assert model.max_output_tokens == 65_536
    end

    test "Gemini 2.5 Flash GA model supports thinking" do
      assert {:ok, model} = ModelRegistry.get("gemini-2.5-flash")
      assert model.name == "Gemini 2.5 Flash"
      assert model.supports_thinking == true
      assert model.max_output_tokens == 65_536
    end

    test "Gemini 2.0 Flash does not support thinking" do
      assert {:ok, model} = ModelRegistry.get("gemini-2.0-flash")
      assert model.supports_thinking == false
      assert model.max_output_tokens == 8192
    end
  end

  describe "context window ranges" do
    test "all Anthropic models have 200k context" do
      for model <- ModelRegistry.list(:anthropic) do
        assert model.context_window == 200_000,
               "Expected #{model.id} to have 200k context, got #{model.context_window}"
      end
    end

    test "all Google models have 1M context" do
      for model <- ModelRegistry.list(:google) do
        assert model.context_window == 1_000_000,
               "Expected #{model.id} to have 1M context, got #{model.context_window}"
      end
    end

    test "all models have positive max_output_tokens" do
      for model <- ModelRegistry.list_all() do
        assert model.max_output_tokens > 0,
               "Expected #{model.id} to have positive max_output_tokens"
      end
    end

    test "max_output_tokens never exceeds context_window" do
      for model <- ModelRegistry.list_all() do
        assert model.max_output_tokens <= model.context_window,
               "Expected #{model.id} max_output_tokens (#{model.max_output_tokens}) <= context_window (#{model.context_window})"
      end
    end
  end

  describe "list/1 string arguments for all providers" do
    test "string 'openai' returns same as atom :openai" do
      assert ModelRegistry.list("openai") == ModelRegistry.list(:openai)
    end

    test "string 'google' returns same as atom :google" do
      assert ModelRegistry.list("google") == ModelRegistry.list(:google)
    end

    test "string unknown provider returns empty list" do
      assert ModelRegistry.list("unknown") == []
      assert ModelRegistry.list("") == []
    end

    test "openai_compat returns openai models" do
      assert ModelRegistry.list(:openai_compat) == ModelRegistry.list(:openai)
      assert ModelRegistry.list("openai_compat") == ModelRegistry.list(:openai)
    end

    test "openrouter returns openai models" do
      assert ModelRegistry.list(:openrouter) == ModelRegistry.list(:openai)
      assert ModelRegistry.list("openrouter") == ModelRegistry.list(:openai)
    end
  end

  describe "list_all/0 count and composition" do
    test "total count equals sum of per-provider counts" do
      all = ModelRegistry.list_all()

      anthropic_count = length(ModelRegistry.list(:anthropic))
      openai_count = length(ModelRegistry.list(:openai))
      google_count = length(ModelRegistry.list(:google))

      assert length(all) == anthropic_count + openai_count + google_count
    end

    test "all three provider lists are non-empty" do
      assert length(ModelRegistry.list(:anthropic)) > 0
      assert length(ModelRegistry.list(:openai)) > 0
      assert length(ModelRegistry.list(:google)) > 0
    end

    test "every model in list_all is retrievable via get/1" do
      for model <- ModelRegistry.list_all() do
        assert {:ok, fetched} = ModelRegistry.get(model.id)
        assert fetched == model
      end
    end

    test "all models support streaming" do
      for model <- ModelRegistry.list_all() do
        assert model.supports_streaming == true,
               "Expected #{model.id} to support streaming"
      end
    end

    test "all models support images" do
      for model <- ModelRegistry.list_all() do
        assert model.supports_images == true,
               "Expected #{model.id} to support images"
      end
    end

    test "all models support tools" do
      for model <- ModelRegistry.list_all() do
        assert model.supports_tools == true,
               "Expected #{model.id} to support tools"
      end
    end
  end
end
