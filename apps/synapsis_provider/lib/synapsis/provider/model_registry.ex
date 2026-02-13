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
      id: "gemini-2.5-flash-preview-05-20",
      name: "Gemini 2.5 Flash",
      provider: "google",
      context_window: 1_000_000,
      max_output_tokens: 65_536,
      supports_tools: true,
      supports_thinking: true,
      supports_images: true,
      supports_streaming: true
    }
  ]

  @all_models @anthropic_models ++ @openai_models ++ @google_models

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
  def list(:google), do: @google_models
  def list("google"), do: @google_models
  def list(_), do: []

  @doc "List all known models across all providers."
  @spec list_all() :: [model_meta()]
  def list_all, do: @all_models
end
