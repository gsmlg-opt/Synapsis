defmodule Synapsis.SamgitaConfig do
  @moduledoc """
  The single Samgita connection entry (`samgita.toml`, id `"default"`).

  Holds the Samgita base URL plus two generated secrets, stored encrypted:

    * `:app_server_token` — the Bearer token Samgita presents to Synapsis `/app-server`
    * `:agent_credential` — the Bearer credential Synapsis presents to the Samgita agent API

  Secrets are returned in plaintext only by `rotate_secret/1` (once, for the operator to copy)
  and `resolve_secret/1` (for runtime use). `get/0` reports only whether each is set.
  """

  alias Synapsis.Config.Store
  alias Synapsis.Encrypted.Binary, as: EncryptedBinary

  @type secret :: :app_server_token | :agent_credential

  @id "default"
  @fields %{app_server_token: "app_server_token_encrypted", agent_credential: "agent_credential_encrypted"}

  @spec get() :: %{base_url: String.t() | nil, app_server_token?: boolean, agent_credential?: boolean}
  def get do
    raw = raw()

    %{
      base_url: raw["base_url"],
      app_server_token?: is_binary(raw[@fields.app_server_token]),
      agent_credential?: is_binary(raw[@fields.agent_credential])
    }
  end

  @spec put_base_url(String.t()) :: :ok | {:error, :invalid_url | term}
  def put_base_url(url) when is_binary(url) do
    with {:ok, url} <- validate_url(String.trim(url)) do
      update(&Map.put(&1, "base_url", url))
    end
  end

  @spec rotate_secret(secret) :: {:ok, String.t()} | {:error, term}
  def rotate_secret(kind) when is_map_key(@fields, kind) do
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with :ok <- update(&Map.put(&1, Map.fetch!(@fields, kind), encrypt(secret))) do
      {:ok, secret}
    end
  end

  @spec resolve_secret(secret) :: {:ok, String.t()} | {:error, :not_configured | :credential_unavailable}
  def resolve_secret(kind) when is_map_key(@fields, kind) do
    case raw()[Map.fetch!(@fields, kind)] do
      nil -> {:error, :not_configured}
      encrypted -> decrypt(encrypted)
    end
  end

  defp raw do
    case Store.get(:samgita, @id) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp update(fun) do
    Store.with_write_lock(fn ->
      entry =
        raw()
        |> Map.put("id", @id)
        |> fun.()
        |> Map.put("updated_at", DateTime.to_iso8601(DateTime.utc_now()))

      case Store.put(:samgita, entry) do
        :ok -> :ok
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp encrypt(secret) do
    {:ok, ciphertext} = EncryptedBinary.dump(secret)
    "enc:v1:" <> Base.encode64(ciphertext)
  end

  defp decrypt("enc:v1:" <> encoded) do
    with {:ok, ciphertext} <- Base.decode64(encoded),
         {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 <-
           EncryptedBinary.load(ciphertext) do
      {:ok, secret}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  defp decrypt(_), do: {:error, :credential_unavailable}
end
