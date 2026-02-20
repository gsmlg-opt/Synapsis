defmodule SynapsisServer.ProviderController do
  use SynapsisServer, :controller

  require Logger

  alias Synapsis.Providers

  def index(conn, _params) do
    {:ok, db_providers} = Providers.list()

    db_data =
      Enum.map(db_providers, fn p ->
        serialize_provider(p)
      end)

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

  defp serialize_provider(%Synapsis.ProviderConfig{} = p) do
    %{
      id: p.id,
      name: p.name,
      type: p.type,
      base_url: p.base_url,
      has_api_key: not is_nil(p.api_key_encrypted),
      config: p.config,
      enabled: p.enabled,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp normalize_attrs(params) do
    params
    |> Map.drop(["id"])
    |> Map.new(fn
      {"api_key", v} -> {:api_key_encrypted, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> params |> Map.drop(["id"])
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
          %{name: "openai", type: "openai_compat", has_api_key: true, source: "env"} | providers
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
