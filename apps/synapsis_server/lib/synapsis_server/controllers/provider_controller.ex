defmodule SynapsisServer.ProviderController do
  use SynapsisServer, :controller

  require Logger

  alias Synapsis.Providers

  def index(conn, _params) do
    {:ok, db_providers} = Providers.list()
    db_data = Enum.map(db_providers, &serialize_provider/1)
    db_names = MapSet.new(db_data, & &1.name)

    env_providers =
      detect_env_providers() |> Enum.reject(fn p -> MapSet.member?(db_names, p.name) end)

    json(conn, %{data: db_data ++ env_providers})
  end

  def create(conn, params) do
    attrs = normalize_attrs(params)

    case Providers.create(attrs) do
      {:ok, provider} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_provider(provider)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Providers.get(id) do
      {:ok, provider} ->
        json(conn, %{data: serialize_provider(provider)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = normalize_attrs(params)

    case Providers.update(id, attrs) do
      {:ok, provider} ->
        json(conn, %{data: serialize_provider(provider)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case Providers.delete(id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})
    end
  end

  def models(conn, %{"id" => id}) do
    case Providers.models(id) do
      {:ok, models} ->
        json(conn, %{data: models})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})

      {:error, :unknown_provider} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Unknown provider type"})

      {:error, reason} ->
        Logger.warning("provider_models_error", provider_id: id, reason: inspect(reason))
        conn |> put_status(500) |> json(%{error: "Failed to retrieve models"})
    end
  end

  def test_connection(conn, %{"id" => id}) do
    case Providers.test_connection(id) do
      {:ok, result} ->
        json(conn, %{data: %{status: "ok", models_count: result.models_count}})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})

      {:error, reason} ->
        Logger.warning("provider_test_connection_error", provider_id: id, reason: inspect(reason))

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{data: %{status: "error", error: "Connection failed"}})
    end
  end

  def models_by_name(conn, %{"name" => name}) do
    case Synapsis.Provider.Registry.module_for(name) do
      {:ok, mod} ->
        config = get_provider_config(name)

        case mod.models(config) do
          {:ok, models} ->
            json(conn, %{data: models})

          {:error, reason} ->
            Logger.warning("provider_models_by_name_error", name: name, reason: inspect(reason))
            conn |> put_status(500) |> json(%{error: "Failed to retrieve models"})
        end

      {:error, _} ->
        conn |> put_status(:not_found) |> json(%{error: "Unknown provider"})
    end
  end

  def authenticate(conn, %{"provider" => provider_name, "api_key" => api_key}) do
    case Providers.get_by_name(provider_name) do
      {:ok, provider} ->
        case Providers.authenticate(provider.id, api_key) do
          {:ok, updated} ->
            json(conn, %{data: serialize_provider(updated)})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(changeset)})
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})
    end
  end

  def authenticate(conn, %{"provider" => _provider_name}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "api_key is required"})
  end

  @doc "Start OAuth device code flow for a provider."
  def oauth_device_start(conn, %{"id" => id}) do
    case Providers.get(id) do
      {:ok, _provider} ->
        case Synapsis.Provider.OAuth.OpenAI.request_user_code() do
          {:ok, device_info} ->
            json(conn, %{
              data: %{
                device_auth_id: device_info.device_auth_id,
                user_code: device_info.user_code,
                interval: device_info.interval,
                verification_url: Synapsis.Provider.OAuth.OpenAI.verification_url()
              }
            })

          {:error, :device_auth_not_enabled} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error:
                "Device code authentication is not enabled for your OpenAI account. Enable it in ChatGPT Settings > Security."
            })

          {:error, reason} ->
            Logger.warning("oauth_device_start_error", provider_id: id, reason: inspect(reason))
            conn |> put_status(500) |> json(%{error: "Failed to start OAuth flow"})
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})
    end
  end

  @doc "Poll OAuth device authorization status and exchange for tokens if authorized."
  def oauth_device_poll(conn, %{
        "id" => id,
        "device_auth_id" => device_auth_id,
        "user_code" => user_code
      }) do
    case Providers.get(id) do
      {:ok, _provider} ->
        case Synapsis.Provider.OAuth.OpenAI.poll_device_token(device_auth_id, user_code) do
          {:ok, auth_result} ->
            case Synapsis.Provider.OAuth.OpenAI.exchange_code(
                   auth_result.authorization_code,
                   auth_result.code_verifier
                 ) do
              {:ok, tokens} ->
                case Providers.save_oauth_tokens(id, tokens) do
                  {:ok, provider} ->
                    json(conn, %{
                      data: %{status: "authorized", provider: serialize_provider(provider)}
                    })

                  {:error, reason} ->
                    Logger.warning("oauth_token_save_error",
                      provider_id: id,
                      reason: inspect(reason)
                    )

                    conn |> put_status(500) |> json(%{error: "Failed to save tokens"})
                end

              {:error, reason} ->
                Logger.warning("oauth_token_exchange_error",
                  provider_id: id,
                  reason: inspect(reason)
                )

                conn |> put_status(500) |> json(%{error: "Token exchange failed"})
            end

          {:pending, :authorization_pending} ->
            json(conn, %{data: %{status: "pending"}})

          {:error, reason} ->
            Logger.warning("oauth_device_poll_error", provider_id: id, reason: inspect(reason))
            conn |> put_status(500) |> json(%{error: "Polling failed"})
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})
    end
  end

  @doc "Refresh OAuth tokens for a provider."
  def oauth_refresh(conn, %{"id" => id}) do
    case Providers.refresh_oauth(id) do
      {:ok, provider} ->
        json(conn, %{data: serialize_provider(provider)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Provider not found"})

      {:error, :not_oauth_provider} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Not an OAuth provider"})

      {:error, :oauth_reauth_required} ->
        conn |> put_status(:unauthorized) |> json(%{error: "Re-authentication required"})

      {:error, reason} ->
        Logger.warning("oauth_refresh_error", provider_id: id, reason: inspect(reason))
        conn |> put_status(500) |> json(%{error: "Token refresh failed"})
    end
  end

  defp serialize_provider(%Synapsis.ProviderConfig{} = p) do
    %{
      id: p.id,
      name: p.name,
      type: p.type,
      base_url: p.base_url,
      has_api_key: not is_nil(p.api_key_encrypted),
      config: p.config,
      enabled: p.enabled,
      model_tiers: Providers.model_tiers(p.name),
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  @allowed_provider_keys %{
    "name" => :name,
    "type" => :type,
    "base_url" => :base_url,
    "api_key" => :api_key_encrypted,
    "config" => :config,
    "enabled" => :enabled
  }

  defp normalize_attrs(params) do
    params
    |> Map.drop(["id"])
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_binary(k) ->
        case Map.fetch(@allowed_provider_keys, k) do
          {:ok, atom_key} -> Map.put(acc, atom_key, v)
          :error -> acc
        end

      _kv, acc ->
        acc
    end)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp detect_env_providers do
    providers = []

    providers =
      if System.get_env("ANTHROPIC_API_KEY"),
        do: [
          %{name: "anthropic", type: "anthropic", has_api_key: true, source: "env"} | providers
        ],
        else: providers

    providers =
      if System.get_env("OPENAI_API_KEY"),
        do: [
          %{name: "openai", type: "openai", has_api_key: true, source: "env"} | providers
        ],
        else: providers

    providers =
      if System.get_env("GOOGLE_API_KEY"),
        do: [%{name: "google", type: "google", has_api_key: true, source: "env"} | providers],
        else: providers

    providers
  end

  defp get_provider_config(name) do
    case Synapsis.Provider.Registry.get(name) do
      {:ok, config} -> config
      {:error, _} -> %{api_key: get_env_key(name), type: name}
    end
  end

  defp get_env_key("anthropic"), do: System.get_env("ANTHROPIC_API_KEY")
  defp get_env_key("openai"), do: System.get_env("OPENAI_API_KEY")
  defp get_env_key("google"), do: System.get_env("GOOGLE_API_KEY")
  defp get_env_key(_), do: nil
end
