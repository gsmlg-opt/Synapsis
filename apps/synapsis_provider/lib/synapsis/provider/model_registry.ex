defmodule Synapsis.Provider.ModelRegistry do
  @moduledoc """
  Static model metadata registry. Provides capabilities, context windows,
  and feature flags for known models across all providers.
  """

  @type model_meta :: %{
          id: String.t(),
          name: String.t(),
          provider: String.t(),
          context_window: pos_integer(),
          max_output_tokens: pos_integer(),
          supports_tools: boolean(),
          supports_thinking: boolean(),
          supports_images: boolean(),
          supports_streaming: boolean()
        }

  @anthropic_models [
    %{
      id: "claude-opus-4-6",
      name: "Claude Opus 4.6",
      provider: "anthropic",
      context_window: 200_000,
      max_output_tokens: 32_000,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      provider: "anthropic",
      context_window: 200_000,
      max_output_tokens: 64_000,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "claude-opus-4-20250514",
      name: "Claude Opus 4",
      provider: "anthropic",
      context_window: 200_000,
      max_output_tokens: 32_000,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "claude-sonnet-4-20250514",
      name: "Claude Sonnet 4",
      provider: "anthropic",
      context_window: 200_000,
      max_output_tokens: 64_000,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "claude-haiku-3-5-20241022",
      name: "Claude 3.5 Haiku",
      provider: "anthropic",
      context_window: 200_000,
      max_output_tokens: 8192,
      supports_tools: true,
      supports_thinking: false,
      supports_images: true,
      supports_streaming: true
    }
  ]

  @openai_models [
    %{
      id: "gpt-4.1",
      name: "GPT-4.1",
      provider: "openai",
      context_window: 1_047_576,
      max_output_tokens: 32_768,
      supports_tools: true,
      supports_thinking: false,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "gpt-4.1-mini",
      name: "GPT-4.1 Mini",
      provider: "openai",
      context_window: 1_047_576,
      max_output_tokens: 32_768,
      supports_tools: true,
      supports_thinking: false,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "gpt-4o",
      name: "GPT-4o",
      provider: "openai",
      context_window: 128_000,
      max_output_tokens: 16_384,
      supports_tools: true,
      supports_thinking: false,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "gpt-4o-mini",
      name: "GPT-4o Mini",
      provider: "openai",
      context_window: 128_000,
      max_output_tokens: 16_384,
      supports_tools: true,
      supports_thinking: false,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "o3",
      name: "o3",
      provider: "openai",
      context_window: 200_000,
      max_output_tokens: 100_000,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "o4-mini",
      name: "o4-mini",
      provider: "openai",
      context_window: 200_000,
      max_output_tokens: 100_000,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    }
  ]

  @google_models [
    %{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      provider: "google",
      context_window: 1_000_000,
      max_output_tokens: 65_536,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "gemini-2.5-flash",
      name: "Gemini 2.5 Flash",
      provider: "google",
      context_window: 1_000_000,
      max_output_tokens: 65_536,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "gemini-2.0-flash",
      name: "Gemini 2.0 Flash",
      provider: "google",
      context_window: 1_000_000,
      max_output_tokens: 8192,
      supports_tools: true,
      supports_thinking: false,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "gemini-2.5-pro-preview-05-06",
      name: "Gemini 2.5 Pro Preview",
      provider: "google",
      context_window: 1_000_000,
      max_output_tokens: 65_536,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    },
    %{
      id: "gemini-2.5-flash-preview-05-20",
      name: "Gemini 2.5 Flash Preview",
      provider: "google",
      context_window: 1_000_000,
      max_output_tokens: 65_536,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    }
  ]

  @moonshot_models [
    %{
      id: "kimi-k2",
      name: "Kimi K2",
      provider: "moonshot",
      context_window: 128_000,
      max_output_tokens: 32_768,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "kimi-k2.5",
      name: "Kimi K2.5",
      provider: "moonshot",
      context_window: 128_000,
      max_output_tokens: 32_768,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "kimi-k2-thinking",
      name: "Kimi K2 Thinking",
      provider: "moonshot",
      context_window: 256_000,
      max_output_tokens: 32_768,
      supports_tools: true,
      supports_thinking: true,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "kimi-k2-0905-preview",
      name: "Kimi K2 (Sep 2025)",
      provider: "moonshot",
      context_window: 256_000,
      max_output_tokens: 32_768,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "moonshot-v1-8k",
      name: "Moonshot V1 8K",
      provider: "moonshot",
      context_window: 8_192,
      max_output_tokens: 4096,
      supports_tools: false,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "moonshot-v1-32k",
      name: "Moonshot V1 32K",
      provider: "moonshot",
      context_window: 32_768,
      max_output_tokens: 4096,
      supports_tools: false,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "moonshot-v1-128k",
      name: "Moonshot V1 128K",
      provider: "moonshot",
      context_window: 128_000,
      max_output_tokens: 4096,
      supports_tools: false,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    }
  ]

  @zhipu_models [
    %{
      id: "glm-4.7",
      name: "GLM-4.7",
      provider: "zhipu",
      context_window: 200_000,
      max_output_tokens: 96_000,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "glm-4.5",
      name: "GLM-4.5",
      provider: "zhipu",
      context_window: 128_000,
      max_output_tokens: 96_000,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "glm-4.5-air",
      name: "GLM-4.5 Air",
      provider: "zhipu",
      context_window: 128_000,
      max_output_tokens: 96_000,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "glm-4.5-flash",
      name: "GLM-4.5 Flash",
      provider: "zhipu",
      context_window: 128_000,
      max_output_tokens: 96_000,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "glm-5",
      name: "GLM-5",
      provider: "zhipu",
      context_window: 200_000,
      max_output_tokens: 96_000,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    }
  ]

  @minimax_models [
    %{
      id: "MiniMax-M2.5",
      name: "MiniMax M2.5",
      provider: "minimax",
      context_window: 204_800,
      max_output_tokens: 40_960,
      supports_tools: true,
      supports_thinking: true,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "MiniMax-M2.5-highspeed",
      name: "MiniMax M2.5 Highspeed",
      provider: "minimax",
      context_window: 204_800,
      max_output_tokens: 40_960,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "MiniMax-M2.1",
      name: "MiniMax M2.1",
      provider: "minimax",
      context_window: 204_800,
      max_output_tokens: 40_960,
      supports_tools: true,
      supports_thinking: true,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "MiniMax-M2.1-highspeed",
      name: "MiniMax M2.1 Highspeed",
      provider: "minimax",
      context_window: 204_800,
      max_output_tokens: 40_960,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    },
    %{
      id: "MiniMax-M2",
      name: "MiniMax M2",
      provider: "minimax",
      context_window: 204_800,
      max_output_tokens: 40_960,
      supports_tools: true,
      supports_thinking: false,
      supports_images: false,
      supports_streaming: true
    }
  ]

  @all_models @anthropic_models ++ @openai_models ++ @google_models ++ @moonshot_models ++ @zhipu_models ++ @minimax_models

  @doc "Look up metadata for a specific model ID."
  @spec get(String.t()) :: {:ok, model_meta()} | {:error, :unknown}
  def get(model_id) do
    case Enum.find(@all_models, fn m -> m.id == model_id end) do
      nil -> {:error, :unknown}
      model -> {:ok, model}
    end
  end

  @doc "List all models for a given provider type."
  @spec list(atom() | String.t()) :: [model_meta()]
  def list(:anthropic), do: @anthropic_models
  def list("anthropic"), do: @anthropic_models
  def list(:openai), do: @openai_models
  def list("openai"), do: @openai_models
  # openai_compat, openrouter, groq, local, deepseek all use OpenAI-compatible models
  def list(:openai_compat), do: @openai_models
  def list("openai_compat"), do: @openai_models
  def list(:openrouter), do: @openai_models
  def list("openrouter"), do: @openai_models
  def list(:google), do: @google_models
  def list("google"), do: @google_models
  def list(:moonshot), do: @moonshot_models
  def list("moonshot"), do: @moonshot_models
  def list(:zhipu), do: @zhipu_models
  def list("zhipu"), do: @zhipu_models
  def list(:minimax), do: @minimax_models
  def list("minimax"), do: @minimax_models
  def list(_), do: []

  @doc "List all known models across all providers."
  @spec list_all() :: [model_meta()]
  def list_all, do: @all_models
end
