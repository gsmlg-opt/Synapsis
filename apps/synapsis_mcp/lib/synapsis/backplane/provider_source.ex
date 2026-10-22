defmodule Synapsis.Backplane.ProviderSource do
  @moduledoc "Resolves Backplane protocol endpoints and credentials from one provider."
  alias Synapsis.Providers

  def get(id, opts \\ []) do
    with {:ok, provider} <- Providers.get(id),
         true <- provider.enabled or Keyword.get(opts, :allow_disabled, false),
         true <- Providers.credential_available?(provider),
         url when is_binary(url) <- provider.base_url do
      endpoint = url |> String.trim_trailing("/") |> String.replace(~r{/v1$}, "")
      {:ok, %{provider: provider, endpoint: endpoint, credential: provider.api_key_encrypted}}
    else
      _ -> {:error, :provider_unavailable}
    end
  end

  def available do
    case Providers.list() do
      {:ok, providers} -> Enum.filter(providers, &backplane?/1)
      _ -> []
    end
  end

  def backplane?(provider) do
    Map.get(provider, :preset) == "backplane" or
      provider.config["managed_by"] == "backplane" or
      provider.config["preset"] == "backplane"
  end
end
