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

  def test_connection(id) do
    case models(id) do
      {:ok, models} -> {:ok, %{status: :ok, models_count: length(models)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def authenticate(id, api_key) do
    update(id, %{api_key_encrypted: api_key})
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

  defp default_base_url("anthropic"), do: "https://api.anthropic.com"
  defp default_base_url("openai"), do: "https://api.openai.com"
  defp default_base_url("openai_compat"), do: "https://api.openai.com"
  defp default_base_url("google"), do: "https://generativelanguage.googleapis.com"
  defp default_base_url("groq"), do: "https://api.groq.com/openai"
  defp default_base_url("deepseek"), do: "https://api.deepseek.com"
  defp default_base_url("openrouter"), do: "https://openrouter.ai/api"
  defp default_base_url("local"), do: "http://localhost:11434"
  defp default_base_url(_), do: nil

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
