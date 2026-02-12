defmodule SynapsisServerWeb.ProviderController do
  use SynapsisServerWeb, :controller

  def index(conn, _params) do
    providers = Synapsis.Provider.Registry.list()

    data =
      Enum.map(providers, fn {name, config} ->
        %{
          name: name,
          base_url: config[:base_url],
          has_api_key: not is_nil(config[:api_key])
        }
      end)

    # Also add providers from env
    env_providers = detect_env_providers()

    json(conn, %{data: data ++ env_providers})
  end

  def models(conn, %{"name" => name}) do
    case Synapsis.Provider.Registry.module_for(name) do
      {:ok, mod} ->
        config = get_provider_config(name)

        case mod.models(config) do
          {:ok, models} -> json(conn, %{data: models})
          {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
        end

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "Unknown provider"})
    end
  end

  defp detect_env_providers do
    providers = []

    providers =
      if System.get_env("ANTHROPIC_API_KEY"),
        do: [%{name: "anthropic", has_api_key: true} | providers],
        else: providers

    providers =
      if System.get_env("OPENAI_API_KEY"),
        do: [%{name: "openai", has_api_key: true} | providers],
        else: providers

    providers =
      if System.get_env("GOOGLE_API_KEY"),
        do: [%{name: "google", has_api_key: true} | providers],
        else: providers

    providers
  end

  defp get_provider_config(name) do
    case Synapsis.Provider.Registry.get(name) do
      {:ok, config} -> config
      {:error, _} -> %{api_key: get_env_key(name)}
    end
  end

  defp get_env_key("anthropic"), do: System.get_env("ANTHROPIC_API_KEY")
  defp get_env_key("openai"), do: System.get_env("OPENAI_API_KEY")
  defp get_env_key("google"), do: System.get_env("GOOGLE_API_KEY")
  defp get_env_key(_), do: nil
end
