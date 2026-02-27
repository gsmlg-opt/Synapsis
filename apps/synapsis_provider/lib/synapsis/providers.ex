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
    %{name: "openrouter", type: "openrouter", base_url: "https://openrouter.ai/api"}
  ]

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
  def default_base_url("local"), do: "http://localhost:11434"
  def default_base_url(_), do: nil

  @doc "Default model for a provider type or named provider."
  def default_model("anthropic"), do: "claude-sonnet-4-6"
  def default_model("openai"), do: "gpt-4.1"
  def default_model("openai-sub"), do: "gpt-4.1"
  def default_model("openai_compat"), do: "gpt-4.1"
  def default_model("openrouter"), do: "openai/gpt-4.1"
  def default_model("google"), do: "gemini-2.5-flash"
  def default_model("moonshot-ai"), do: "kimi-k2"
  def default_model("moonshot-cn"), do: "kimi-k2"
  def default_model("zhipu-ai"), do: "glm-4.7"
  def default_model("zhipu-cn"), do: "glm-4.7"
  def default_model("zhipu-coding"), do: "glm-4.7"
  def default_model(_), do: "gpt-4.1"

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
end
