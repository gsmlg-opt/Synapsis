defmodule Synapsis.Provider.Realtime.Catalog do
  @moduledoc "Realtime model discovery and server-side Backplane connection configuration."

  alias Synapsis.Provider.Transport.HTTP, as: Transport

  @doc "Resolve the root Realtime endpoints without changing the credential scope."
  def connection(config) when is_map(config) do
    with :ok <- authentication_mode(config),
         base when is_binary(base) <- value(config, :base_url),
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri <-
           URI.parse(base),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         :ok <- endpoint_scope(uri.path || ""),
         path = String.trim_trailing(uri.path || "", "/"),
         true <- path in ["", "/v1"] do
      root = URI.to_string(%{uri | path: "/v1/realtime"})

      websocket =
        URI.to_string(%{
          uri
          | path: "/v1/realtime",
            scheme: if(scheme == "https", do: "wss", else: "ws")
        })

      credential = value(config, :api_key)

      headers =
        if is_binary(credential) and credential != "",
          do: [{"authorization", "Bearer " <> credential}],
          else: []

      {:ok, %{models_url: root <> "/models", websocket_url: websocket, headers: headers}}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_base_url}
      _ -> {:error, :invalid_base_url}
    end
  end

  def connection(_), do: {:error, :invalid_base_url}

  @doc "Fetch the independent Realtime directory with a bounded, non-retrying request."
  def list(config, opts \\ []) do
    with {:ok, config} <- Synapsis.Providers.refresh_runtime_auth(config),
         {:ok, connection} <- connection(config),
         {:ok, response} <-
           Transport.json(connection.models_url,
             headers: connection.headers,
             timeout: Keyword.get(opts, :timeout, 5_000),
             max_bytes: 1_048_576
           ) do
      models(response)
    end
  end

  defp models(%{status: 200, body: %{"data" => models}}) when is_list(models) do
    if Enum.all?(models, &valid_model?/1) do
      {:ok,
       models
       |> Enum.map(&%{id: &1["id"], name: &1["name"] || &1["id"]})
       |> Enum.uniq_by(& &1.id)}
    else
      {:error, :invalid_catalog}
    end
  end

  defp models(%{status: 401}), do: {:error, :unauthorized}
  defp models(%{status: 403}), do: {:error, :forbidden}
  defp models(%{status: 404}), do: {:error, :realtime_not_configured}
  defp models(%{status: status}) when status != 200, do: {:error, {:http_status, status}}
  defp models(_), do: {:error, :invalid_catalog}

  defp valid_model?(%{"id" => id} = model) when is_binary(id) do
    byte_size(id) <= 1_024 and Regex.match?(~r/\A[^\s\/]+\/[^\s]+\z/, id) and
      (is_nil(model["name"]) or is_binary(model["name"]))
  end

  defp valid_model?(_), do: false

  defp authentication_mode(config) do
    if value(config, :oauth) == true, do: {:error, :oauth_unsupported}, else: :ok
  end

  defp endpoint_scope(path) do
    if "endpoints" in String.split(path, "/"),
      do: {:error, :named_endpoint_unsupported},
      else: :ok
  end

  defp value(config, key), do: Map.get(config, key, Map.get(config, Atom.to_string(key)))
end
