defmodule Synapsis.Providers do
  @moduledoc "Public API for provider configuration management."

  alias Synapsis.{Repo, ProviderConfig}
  alias Synapsis.Provider.Registry, as: ProviderRegistry
  import Ecto.Query, only: [from: 2, where: 3]

  def create(attrs) do
    result =
      %ProviderConfig{}
      |> ProviderConfig.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, provider} ->
        sync_to_registry(provider)
        {:ok, provider}

      error ->
        error
    end
  end

  def get(id) do
    case Repo.get(ProviderConfig, id) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  def get_by_name(name) do
    case Repo.get_by(ProviderConfig, name: name) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  def list(opts \\ []) do
    query = from(p in ProviderConfig, order_by: [asc: p.name])

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> where(query, [p], p.enabled == ^enabled)
      end

    {:ok, Repo.all(query)}
  end

  def update(id, attrs) do
    with {:ok, provider} <- get(id) do
      result =
        provider
        |> ProviderConfig.update_changeset(attrs)
        |> Repo.update()

      case result do
        {:ok, updated} ->
          sync_to_registry(updated)
          {:ok, updated}

        error ->
          error
      end
    end
  end

  def delete(id) do
    with {:ok, provider} <- get(id) do
      ProviderRegistry.unregister(provider.name)
      Repo.delete(provider)
    end
  end

  def models(id) do
    with {:ok, provider} <- get(id),
         {:ok, mod} <- ProviderRegistry.module_for(provider.type) do
      config = build_runtime_config(provider)
      mod.models(config)
    end
  end

  @doc "Fetch available models for a provider by name."
  def models_for(provider_name) do
    case get_by_name(provider_name) do
      {:ok, provider} ->
        config = build_runtime_config(provider)
        Synapsis.Provider.Adapter.models(config)

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Fetch all available models for a provider by id."
  def models_by_id(id) do
    case get(id) do
      {:ok, provider} ->
        config = build_runtime_config(provider)
        Synapsis.Provider.Adapter.models(config)

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Return the list of enabled model IDs for a provider. Empty list means all models enabled."
  def enabled_models(%ProviderConfig{config: config}) do
    case config do
      %{"enabled_models" => models} when is_list(models) -> models
      _ -> []
    end
  end

  def test_connection(id) do
    case models(id) do
      {:ok, models} -> {:ok, %{status: :ok, models_count: length(models)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def authenticate(id, api_key) do
    update(id, %{api_key_encrypted: api_key})
  end

  @default_providers [
    %{name: "anthropic", type: "anthropic", base_url: "https://api.anthropic.com"},
    %{name: "openai", type: "openai", base_url: "https://api.openai.com"},
    %{name: "openai-sub", type: "openai", base_url: "https://api.chatgpt.com"},
    %{name: "moonshot-ai", type: "anthropic", base_url: "https://api.moonshot.ai/anthropic"},
    %{name: "moonshot-cn", type: "anthropic", base_url: "https://api.moonshot.cn/anthropic"},
    %{name: "zhipu-ai", type: "anthropic", base_url: "https://api.z.ai/api/anthropic"},
    %{name: "zhipu-cn", type: "anthropic", base_url: "https://open.bigmodel.cn/api/anthropic"},
    %{
      name: "zhipu-coding",
      type: "anthropic",
      base_url: "https://open.bigmodel.cn/api/anthropic"
    },
    %{name: "minimax-io", type: "anthropic", base_url: "https://api.minimax.io/anthropic"},
    %{name: "minimax-cn", type: "anthropic", base_url: "https://api.minimaxi.com/anthropic"},
    %{name: "openrouter", type: "openrouter", base_url: "https://openrouter.ai/api"}
  ]

  @doc "Return the list of known provider presets (name, type, base_url)."
  def preset_providers, do: @default_providers

  @doc "Insert default providers (idempotent — skips existing names)."
  def seed_defaults do
    Enum.each(@default_providers, fn attrs ->
      %ProviderConfig{}
      |> ProviderConfig.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
    end)

    :ok
  end

  def load_all_into_registry do
    {:ok, providers} = list(enabled: true)

    Enum.each(providers, fn provider ->
      sync_to_registry(provider)
    end)

    :ok
  end

  defp sync_to_registry(%ProviderConfig{enabled: true} = provider) do
    config = build_runtime_config(provider)
    ProviderRegistry.register(provider.name, config)
  end

  defp sync_to_registry(%ProviderConfig{enabled: false} = provider) do
    ProviderRegistry.unregister(provider.name)
  end

  defp build_runtime_config(%ProviderConfig{} = provider) do
    base = %{
      api_key: provider.api_key_encrypted,
      type: provider.type
    }

    base =
      if provider.base_url do
        Map.put(base, :base_url, provider.base_url)
      else
        Map.put(base, :base_url, default_base_url(provider.type))
      end

    Map.merge(base, atomize_keys(provider.config || %{}))
  end

  @doc "Default base URL for a provider type or named provider."
  def default_base_url("anthropic"), do: "https://api.anthropic.com"
  def default_base_url("openai"), do: "https://api.openai.com"
  def default_base_url("openai-sub"), do: "https://api.chatgpt.com"
  def default_base_url("openai_compat"), do: "https://api.openai.com"
  def default_base_url("google"), do: "https://generativelanguage.googleapis.com"
  def default_base_url("groq"), do: "https://api.groq.com/openai"
  def default_base_url("deepseek"), do: "https://api.deepseek.com"
  def default_base_url("openrouter"), do: "https://openrouter.ai/api"
  def default_base_url("moonshot-ai"), do: "https://api.moonshot.ai/anthropic"
  def default_base_url("moonshot-cn"), do: "https://api.moonshot.cn/anthropic"
  def default_base_url("zhipu-ai"), do: "https://api.z.ai/api/anthropic"
  def default_base_url("zhipu-cn"), do: "https://open.bigmodel.cn/api/anthropic"
  def default_base_url("zhipu-coding"), do: "https://open.bigmodel.cn/api/anthropic"
  def default_base_url("minimax-io"), do: "https://api.minimax.io/anthropic"
  def default_base_url("minimax-cn"), do: "https://api.minimaxi.com/anthropic"
  def default_base_url("local"), do: "http://localhost:11434"
  def default_base_url(_), do: nil

  @doc "Default model for a provider type or named provider."
  def default_model("anthropic"), do: "claude-sonnet-4-6"
  def default_model("openai"), do: "gpt-4.1"
  def default_model("openai-sub"), do: "gpt-4.1"
  def default_model("openai_compat"), do: "gpt-4.1"
  def default_model("openrouter"), do: "openai/gpt-4.1"
  def default_model("google"), do: "gemini-2.5-flash"
  def default_model("moonshot-ai"), do: "kimi-k2.5"
  def default_model("moonshot-cn"), do: "kimi-k2.5"
  def default_model("zhipu-ai"), do: "glm-4.7"
  def default_model("zhipu-cn"), do: "glm-4.7"
  def default_model("zhipu-coding"), do: "glm-4.7"
  def default_model("minimax-io"), do: "MiniMax-M2.5"
  def default_model("minimax-cn"), do: "MiniMax-M2.5"

  def default_model(provider_name) do
    # For custom-named providers, look up their config and infer default model from base_url
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        base_url = config[:base_url] || ""

        cond do
          String.contains?(base_url, "moonshot") ->
            "kimi-k2.5"

          String.contains?(base_url, "bigmodel") or String.contains?(base_url, "z.ai") ->
            "glm-4.7"

          String.contains?(base_url, "minimax") ->
            "MiniMax-M2.5"

          String.contains?(base_url, "anthropic.com") ->
            "claude-sonnet-4-6"

          String.contains?(base_url, "openai.com") or String.contains?(base_url, "chatgpt.com") ->
            "gpt-4.1"

          String.contains?(base_url, "googleapis.com") ->
            "gemini-2.5-flash"

          String.contains?(base_url, "openrouter") ->
            "openai/gpt-4.1"

          true ->
            "gpt-4.1"
        end

      {:error, _} ->
        "gpt-4.1"
    end
  end

  @doc "Return the model for a given tier (:default | :fast | :expert) and provider."
  def model_for_tier(provider_name, tier \\ :default)

  def model_for_tier(provider_name, :default), do: default_model(provider_name)

  def model_for_tier(provider_name, :fast) do
    case provider_name do
      "anthropic" -> "claude-haiku-3-5-20241022"
      "openai" -> "gpt-4.1-mini"
      "openai-sub" -> "gpt-4.1-mini"
      "google" -> "gemini-2.0-flash"
      "moonshot-ai" -> "kimi-k2-turbo-preview"
      "moonshot-cn" -> "kimi-k2-turbo-preview"
      "zhipu-ai" -> "glm-4-flash"
      "zhipu-cn" -> "glm-4-flash"
      "zhipu-coding" -> "codegeex-4"
      "minimax-io" -> "MiniMax-M1"
      "minimax-cn" -> "MiniMax-M1"
      "openrouter" -> "openai/gpt-4.1-mini"
      _ -> infer_fast_from_registry(provider_name)
    end
  end

  def model_for_tier(provider_name, :expert) do
    case provider_name do
      "anthropic" -> "claude-opus-4-6"
      "openai" -> "o3"
      "openai-sub" -> "o3"
      "google" -> "gemini-2.5-pro"
      "moonshot-ai" -> "kimi-k2-thinking"
      "moonshot-cn" -> "kimi-k2-thinking"
      "zhipu-ai" -> "glm-4.7"
      "zhipu-cn" -> "glm-4.7"
      "zhipu-coding" -> "glm-4.7"
      "minimax-io" -> "MiniMax-M2.5"
      "minimax-cn" -> "MiniMax-M2.5"
      "openrouter" -> "anthropic/claude-opus-4-6"
      _ -> infer_expert_from_registry(provider_name)
    end
  end

  @doc "Return all three tier models for a provider."
  def model_tiers(provider_name) do
    %{
      default: model_for_tier(provider_name, :default),
      fast: model_for_tier(provider_name, :fast),
      expert: model_for_tier(provider_name, :expert)
    }
  end

  @doc "Environment variable name for a provider's API key."
  def env_var_name("anthropic"), do: "ANTHROPIC_API_KEY"
  def env_var_name("openai"), do: "OPENAI_API_KEY"
  def env_var_name("openai-sub"), do: "CHATGPT_OAUTH_TOKEN"
  def env_var_name("google"), do: "GOOGLE_API_KEY"
  def env_var_name("moonshot-ai"), do: "MOONSHOT_API_KEY"
  def env_var_name("moonshot-cn"), do: "MOONSHOT_API_KEY"
  def env_var_name("zhipu-ai"), do: "ZHIPU_API_KEY"
  def env_var_name("zhipu-cn"), do: "ZHIPU_API_KEY"
  def env_var_name("zhipu-coding"), do: "ZHIPU_API_KEY"
  def env_var_name("minimax-io"), do: "MINIMAX_API_KEY"
  def env_var_name("minimax-cn"), do: "MINIMAX_API_KEY"
  def env_var_name("openrouter"), do: "OPENROUTER_API_KEY"
  def env_var_name(_), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {safe_to_atom(k), v} end)
  end

  defp safe_to_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp safe_to_atom(k), do: k

  defp infer_fast_from_registry(provider_name) do
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        base_url = config[:base_url] || ""

        cond do
          String.contains?(base_url, "moonshot") ->
            "kimi-k2-turbo-preview"

          String.contains?(base_url, "bigmodel") or String.contains?(base_url, "z.ai") ->
            "glm-4-flash"

          String.contains?(base_url, "minimax") ->
            "MiniMax-M1"

          String.contains?(base_url, "anthropic.com") ->
            "claude-haiku-3-5-20241022"

          String.contains?(base_url, "openai.com") or String.contains?(base_url, "chatgpt.com") ->
            "gpt-4.1-mini"

          String.contains?(base_url, "googleapis.com") ->
            "gemini-2.0-flash"

          String.contains?(base_url, "openrouter") ->
            "openai/gpt-4.1-mini"

          true ->
            "gpt-4.1-mini"
        end

      {:error, _} ->
        "gpt-4.1-mini"
    end
  end

  defp infer_expert_from_registry(provider_name) do
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        base_url = config[:base_url] || ""

        cond do
          String.contains?(base_url, "moonshot") ->
            "kimi-k2-thinking"

          String.contains?(base_url, "bigmodel") or String.contains?(base_url, "z.ai") ->
            "glm-4.7"

          String.contains?(base_url, "minimax") ->
            "MiniMax-M2.5"

          String.contains?(base_url, "anthropic.com") ->
            "claude-opus-4-6"

          String.contains?(base_url, "openai.com") or String.contains?(base_url, "chatgpt.com") ->
            "o3"

          String.contains?(base_url, "googleapis.com") ->
            "gemini-2.5-pro"

          String.contains?(base_url, "openrouter") ->
            "anthropic/claude-opus-4-6"

          true ->
            "o3"
        end

      {:error, _} ->
        "o3"
    end
  end
end
