defmodule Synapsis.LocalAgentConfigs do
  @moduledoc "Context for local agent definitions persisted in `local_agents.toml`."

  alias Synapsis.Config.Store
  alias Synapsis.Encrypted.Binary, as: EncryptedBinary
  alias Synapsis.LocalAgentConfig

  @store_type :local_agent
  @fields ~w(name kind executable args cwd codex_home url repository token_encrypted autostart)a

  @spec list() :: [LocalAgentConfig.t()]
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(&{&1.name, &1.id})
  end

  @spec get(String.t()) :: LocalAgentConfig.t() | nil
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  def create(attrs) when is_map(attrs) do
    changeset = LocalAgentConfig.changeset(%LocalAgentConfig{}, attrs)

    with {:ok, record} <- Ecto.Changeset.apply_action(changeset, :insert) do
      record = %{record | id: record.id || Ecto.UUID.generate()}

      case Store.put(@store_type, to_store_map(record)) do
        :ok -> {:ok, record}
        {:ok, _} -> {:ok, record}
        error -> error
      end
    end
  end

  def update(%LocalAgentConfig{id: id}, attrs) when is_map(attrs) do
    Store.with_write_lock(fn ->
      with {:ok, current} <- Store.get(@store_type, id),
           changeset = LocalAgentConfig.changeset(to_struct(current), Map.drop(attrs, [:id, "id"])),
           {:ok, record} <- Ecto.Changeset.apply_action(changeset, :update),
           {:ok, merged} <- Store.replace_existing(@store_type, id, to_store_map(record)) do
        {:ok, to_struct(merged)}
      end
    end)
  end

  def delete(%LocalAgentConfig{id: id} = config) do
    with :ok <- Store.delete(@store_type, id), do: {:ok, config}
  end

  @doc """
  Generate a new Bearer token for a Sigma agent and store it encrypted. The
  plaintext is returned only here, for the operator to copy into Sigma's
  `SIGMA_PROTOCOL_TOKEN`; generating again invalidates the previous token.
  """
  @spec rotate_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def rotate_token(id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Store.with_write_lock(fn ->
      with {:ok, current} <- Store.get(@store_type, id),
           "sigma" <- current["kind"] || {:error, :unsupported_kind},
           {:ok, _} <-
             Store.replace_existing(
               @store_type,
               id,
               Map.put(current, "token_encrypted", encrypt(token))
             ) do
        {:ok, token}
      else
        kind when is_binary(kind) -> {:error, :unsupported_kind}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "The plaintext token of agent `id`, for runtime use only."
  @spec resolve_token(String.t()) ::
          {:ok, String.t()} | {:error, :not_configured | :credential_unavailable}
  def resolve_token(id) do
    case get(id) do
      %LocalAgentConfig{token_encrypted: encrypted} when is_binary(encrypted) -> decrypt(encrypted)
      _ -> {:error, :not_configured}
    end
  end

  @doc "Create the default Codex entry when none exists and `codex` is on PATH."
  @spec ensure_default_codex() :: :ok
  def ensure_default_codex do
    Store.with_write_lock(fn ->
      executable = System.find_executable("codex")

      if executable && not Enum.any?(list(), &(&1.kind == "codex")) do
        {:ok, _} = create(%{name: "Codex", kind: "codex", executable: executable})
      end

      :ok
    end)
  end

  defp to_struct(map) do
    record = %LocalAgentConfig{} |> LocalAgentConfig.changeset(map) |> Ecto.Changeset.apply_changes()
    %{record | id: map["id"] || record.id, token_encrypted: map["token_encrypted"]}
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

  defp to_store_map(%LocalAgentConfig{} = r) do
    @fields
    |> Map.new(&{Atom.to_string(&1), Map.fetch!(r, &1)})
    |> Map.put("id", r.id)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
