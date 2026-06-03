defmodule Synapsis.Providers do
  @moduledoc "Public API for provider configuration management."

  # ADR-006 C4: provider configs persist in the file-backed Config.Store
  # (TOML), keyed by id. Records round-trip as `%ProviderConfig{}` structs
  # (the PluginConfigs pattern); the in-memory Provider.Registry remains the
  # runtime authority.
  alias Synapsis.{Config.Store, ProviderConfig}
  alias Synapsis.Provider.Registry, as: ProviderRegistry

  @store_type :provider

  def create(attrs) do
    %ProviderConfig{}
    |> ProviderConfig.changeset(attrs)
    |> check_unique_name(nil)
    |> persist()
  end

  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> {:ok, to_struct(map)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def get_by_name(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  def list(opts \\ []) do
    providers =
      all()
      |> Enum.sort_by(&(&1.name || ""))
      |> filter_enabled(Keyword.get(opts, :enabled))

    {:ok, providers}
  end

  defp all, do: @store_type |> Store.list() |> Enum.map(&to_struct/1)

  defp filter_enabled(providers, nil), do: providers

  defp filter_enabled(providers, enabled) when is_boolean(enabled),
    do: Enum.filter(providers, &(&1.enabled == enabled))

  def update(id, attrs) do
    with {:ok, provider} <- get(id) do
      provider
      |> ProviderConfig.changeset(attrs)
      |> check_unique_name(id)
      |> persist()
    end
  end

  def delete(id) do
    with {:ok, provider} <- get(id) do
      ProviderRegistry.unregister(provider.name)
      Store.delete(@store_type, id)
      {:ok, provider}
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
        case cached_models(provider) do
          [] ->
            config = build_runtime_config(provider)
            Synapsis.Provider.Adapter.models(config)

          models ->
            {:ok, models}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Fetch all available models for a provider by id."
  def models_by_id(id) do
    case get(id) do
      {:ok, provider} ->
        provider
        |> cached_models()
        |> case do
          [] ->
            config = build_runtime_config(provider)
            Synapsis.Provider.Adapter.models(config)

          models ->
            {:ok, models}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Refresh provider models from the provider's /models endpoint and cache them in config."
  def refresh_models(id) do
    with {:ok, provider} <- get(id),
         {:ok, models} <- fetch_models(provider) do
      config =
        (provider.config || %{})
        |> Map.merge(%{
          "available_models" => Enum.map(models, &stringify_model/1),
          "models_refreshed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      update(id, %{config: config})
    end
  end

  @doc "Fetch provider models from the remote endpoint, bypassing any cached config."
  def fetch_models(provider) when is_map(provider) do
    provider
    |> build_runtime_config()
    |> Map.put(:discover_models, true)
    |> Synapsis.Provider.Adapter.models()
  end

  @doc "Return cached discovered models for a provider."
  def cached_models(%ProviderConfig{config: config}), do: cached_models_from(config)
  def cached_models(%{"config" => config}), do: cached_models_from(config)
  def cached_models(_), do: []

  defp cached_models_from(%{"available_models" => models}) when is_list(models),
    do: Enum.map(models, &normalize_model/1)

  defp cached_models_from(_), do: []

  @doc "Return the list of enabled model IDs for a provider. Empty list means all models enabled."
  def enabled_models(%ProviderConfig{config: %{"enabled_models" => models}}) when is_list(models),
    do: models

  def enabled_models(_), do: []

  defp stringify_model(model) do
    model
    |> Map.take([:id, :name, :context_window])
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp normalize_model(%{id: id} = model) do
    %{
      id: id,
      name: model[:name] || id,
      context_window: model[:context_window] || 128_000
    }
  end

  defp normalize_model(%{"id" => id} = model) do
    %{
      id: id,
      name: model["name"] || id,
      context_window: model["context_window"] || 128_000
    }
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

  @doc "Store OAuth tokens in the provider's config JSONB and set the access_token as api_key."
  def save_oauth_tokens(id, tokens) do
    with {:ok, provider} <- get(id) do
      oauth_config = Synapsis.Provider.OAuth.OpenAI.build_token_config(tokens)
      merged_config = Map.merge(provider.config || %{}, oauth_config)

      update(id, %{
        api_key_encrypted: tokens.access_token,
        config: merged_config
      })
    end
  end

  @doc "Refresh OAuth tokens for a provider if needed. Returns {:ok, provider} or {:error, reason}."
  def refresh_oauth_if_needed(id) do
    with {:ok, provider} <- get(id),
         true <- oauth_provider?(provider),
         true <- Synapsis.Provider.OAuth.OpenAI.needs_refresh?(provider.config) do
      do_refresh_oauth(provider)
    else
      false -> get(id)
      other -> other
    end
  end

  @doc "Force refresh OAuth tokens for a provider."
  def refresh_oauth(id) do
    with {:ok, provider} <- get(id),
         true <- oauth_provider?(provider) do
      do_refresh_oauth(provider)
    else
      false -> {:error, :not_oauth_provider}
      other -> other
    end
  end

  @doc "Check if a provider uses OAuth authentication."
  def oauth_provider?(%ProviderConfig{config: %{"auth_mode" => "oauth_device"}}), do: true
  def oauth_provider?(_), do: false

  defp do_refresh_oauth(provider) do
    case Synapsis.Provider.OAuth.OpenAI.refresh_token_from_config(provider.config) do
      nil ->
        {:error, :no_refresh_token}

      refresh_token ->
        case Synapsis.Provider.OAuth.OpenAI.refresh_token(refresh_token) do
          {:ok, new_tokens} ->
            save_oauth_tokens(provider.id, new_tokens)

          {:error, {:token_expired, _code}} ->
            {:error, :oauth_reauth_required}

          {:error, reason} ->
            {:error, reason}
        end
    end
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
    existing = MapSet.new(all(), & &1.name)

    Enum.each(@default_providers, fn attrs ->
      unless MapSet.member?(existing, attrs.name), do: create(attrs)
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

  defp sync_to_registry(%ProviderConfig{} = provider) do
    if provider.enabled do
      ProviderRegistry.register(provider.name, build_runtime_config(provider))
    else
      ProviderRegistry.unregister(provider.name)
    end
  end

  defp build_runtime_config(%ProviderConfig{} = provider) do
    config = provider.config || %{}

    # For OAuth providers, prefer the access_token from config (may be fresher)
    api_key =
      case Synapsis.Provider.OAuth.OpenAI.access_token_from_config(config) do
        nil -> provider.api_key_encrypted
        token -> token
      end

    base = %{
      api_key: api_key,
      type: provider.type,
      provider_id: provider.id
    }

    base =
      if provider.base_url do
        Map.put(base, :base_url, provider.base_url)
      else
        Map.put(base, :base_url, default_base_url(provider.type))
      end

    # Mark OAuth providers so transport can attempt refresh on 401
    base =
      if oauth_provider?(provider) do
        Map.put(base, :oauth, true)
      else
        base
      end

    Map.merge(base, atomize_keys(config))
  end

  # ADR-006 C4 store <-> struct mapping (the PluginConfigs pattern).
  defp persist(%Ecto.Changeset{valid?: true} = changeset) do
    record =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> ensure_id()
      |> ensure_timestamps()

    case Store.put(@store_type, to_store_map(record)) do
      :ok ->
        sync_to_registry(record)
        {:ok, record}

      {:ok, _} ->
        sync_to_registry(record)
        {:ok, record}

      error ->
        error
    end
  end

  defp persist(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp check_unique_name(%Ecto.Changeset{valid?: false} = changeset, _id), do: changeset

  defp check_unique_name(changeset, id) do
    name = Ecto.Changeset.get_field(changeset, :name)

    if Enum.any?(all(), &(&1.name == name and &1.id != id)) do
      Ecto.Changeset.add_error(changeset, :name, "has already been taken")
    else
      changeset
    end
  end

  defp ensure_id(%ProviderConfig{id: nil} = record), do: %{record | id: Ecto.UUID.generate()}
  defp ensure_id(record), do: record

  defp ensure_timestamps(%ProviderConfig{} = record) do
    now = DateTime.utc_now()
    %{record | inserted_at: record.inserted_at || now, updated_at: now}
  end

  defp to_struct(map) do
    %ProviderConfig{}
    |> ProviderConfig.changeset(map)
    |> Ecto.Changeset.apply_changes()
    |> restore_meta(map)
  end

  defp restore_meta(%ProviderConfig{} = record, map) do
    %{
      record
      | id: map[:id] || map["id"] || record.id,
        inserted_at: map[:inserted_at] || map["inserted_at"] || record.inserted_at,
        updated_at: map[:updated_at] || map["updated_at"] || record.updated_at
    }
  end

  defp to_store_map(%ProviderConfig{} = r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "type" => r.type,
      "base_url" => r.base_url,
      "api_key_encrypted" => r.api_key_encrypted,
      "config" => r.config || %{},
      "enabled" => r.enabled,
      "inserted_at" => encode_time(r.inserted_at),
      "updated_at" => encode_time(r.updated_at)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp encode_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_time(other), do: other

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

  @doc "Runtime provider type for a provider name."
  def provider_type(provider_name) do
    case provider_name do
      name
      when name in ~w(moonshot-ai moonshot-cn zhipu-ai zhipu-cn zhipu-coding minimax-io minimax-cn) ->
        "anthropic"

      name ->
        name
    end
  end

  @doc "Default model for a provider type or named provider."
  def default_model("anthropic"), do: "claude-sonnet-4-6"
  def default_model("openai"), do: "gpt-4.1"
  def default_model("openai-sub"), do: "gpt-4.1"
  def default_model("openai_compat"), do: "gpt-4.1"
  def default_model("openrouter"), do: "openai/gpt-4.1"
  def default_model("google"), do: "gemini-2.5-flash"
  def default_model("moonshot-ai"), do: "kimi-k2.5"
  def default_model("moonshot-cn"), do: "kimi-k2.5"
  def default_model("zhipu-ai"), do: "glm-5.1"
  def default_model("zhipu-cn"), do: "glm-5.1"
  def default_model("zhipu-coding"), do: "glm-5.1"
  def default_model("minimax-io"), do: "MiniMax-M2.7"
  def default_model("minimax-cn"), do: "MiniMax-M2.7"

  def default_model(provider_name) do
    # For custom-named providers, look up their config and infer default model from base_url
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        base_url = config[:base_url] || ""

        cond do
          String.contains?(base_url, "moonshot") ->
            "kimi-k2.5"

          String.contains?(base_url, "bigmodel") or String.contains?(base_url, "z.ai") ->
            "glm-5.1"

          String.contains?(base_url, "minimax") ->
            "MiniMax-M2.7"

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
      "zhipu-ai" -> "glm-5.1"
      "zhipu-cn" -> "glm-5.1"
      "zhipu-coding" -> "glm-5.1"
      "minimax-io" -> "MiniMax-M2.7"
      "minimax-cn" -> "MiniMax-M2.7"
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

  @doc "Environment variable name for a provider's primary API key."
  def env_var_name(provider_name) do
    provider_name
    |> env_var_names()
    |> List.first()
  end

  @doc "Environment variable names accepted for a provider's API key, in priority order."
  def env_var_names("anthropic"), do: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
  def env_var_names("openai"), do: ["OPENAI_API_KEY"]
  def env_var_names("openai-sub"), do: ["CHATGPT_OAUTH_TOKEN"]
  def env_var_names("google"), do: ["GOOGLE_API_KEY"]
  def env_var_names("moonshot-ai"), do: ["MOONSHOT_API_KEY"]
  def env_var_names("moonshot-cn"), do: ["MOONSHOT_API_KEY"]
  def env_var_names("zhipu-ai"), do: ["ZHIPU_API_KEY"]
  def env_var_names("zhipu-cn"), do: ["ZHIPU_API_KEY"]
  def env_var_names("zhipu-coding"), do: ["ZHIPU_API_KEY"]
  def env_var_names("minimax-io"), do: ["MINIMAX_API_KEY"]
  def env_var_names("minimax-cn"), do: ["MINIMAX_API_KEY"]
  def env_var_names("openrouter"), do: ["OPENROUTER_API_KEY"]
  def env_var_names(_), do: []

  @doc "Return the first configured API key for a provider from the environment."
  def env_api_key(provider_name) do
    provider_name
    |> env_var_names()
    |> Enum.find_value(&present_env/1)
  end

  @doc "Return true when a provider is configured through environment variables."
  def env_configured?(provider_name), do: present?(env_api_key(provider_name))

  @doc "Return a provider base URL override from the environment."
  def env_base_url(provider_name) do
    provider_name
    |> env_base_url_var()
    |> present_env()
  end

  @doc "Return a provider default model override from the environment."
  def env_default_model(provider_name), do: env_model_for_tier(provider_name, :default)

  @doc "Return a provider model override for a tier from the environment."
  def env_model_for_tier(provider_name, tier) do
    provider_name
    |> env_model_vars(tier)
    |> Enum.find_value(&present_env/1)
  end

  defp env_base_url_var("anthropic"), do: "ANTHROPIC_BASE_URL"
  defp env_base_url_var("openai"), do: "OPENAI_BASE_URL"
  defp env_base_url_var("openai-sub"), do: "CHATGPT_BASE_URL"
  defp env_base_url_var("google"), do: "GOOGLE_BASE_URL"
  defp env_base_url_var("openrouter"), do: "OPENROUTER_BASE_URL"
  defp env_base_url_var(_), do: nil

  defp env_model_vars("anthropic", :default),
    do: ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL"]

  defp env_model_vars("anthropic", :fast),
    do: ["ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_FAST_MODEL"]

  defp env_model_vars("anthropic", :expert),
    do: ["ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_EXPERT_MODEL"]

  defp env_model_vars("openai", :default), do: ["OPENAI_MODEL", "OPENAI_DEFAULT_MODEL"]
  defp env_model_vars("openai-sub", :default), do: ["CHATGPT_MODEL", "OPENAI_MODEL"]
  defp env_model_vars("google", :default), do: ["GOOGLE_MODEL", "GOOGLE_DEFAULT_MODEL"]
  defp env_model_vars("openrouter", :default), do: ["OPENROUTER_MODEL"]
  defp env_model_vars(_provider_name, _tier), do: []

  defp present_env(nil), do: nil

  defp present_env(var_name) do
    case System.get_env(var_name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {safe_to_atom(k), v} end)
  end

  defp safe_to_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    _e in [ArgumentError] -> k
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
            "glm-5.1"

          String.contains?(base_url, "minimax") ->
            "MiniMax-M2.7"

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
