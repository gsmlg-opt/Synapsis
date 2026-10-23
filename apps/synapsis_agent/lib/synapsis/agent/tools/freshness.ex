defmodule Synapsis.Agent.Tools.Freshness do
  @moduledoc """
  Captures opaque host evidence for an explicit finite dependency selection.

  `capture/3` requires both `provider_ids` and `credential_ids`, including explicit
  empty lists. Readers are trusted host functions, never model-controlled input:
  `permission.(session_id)` returns `{:ok, raw_permission}`; `provider.(id)` returns
  `{:ok, Providers.authentication_generation(current_available_provider)}`;
  `credential.(id)` returns `{:ok, version}` only after resolving availability.
  Default readers use current Store/Providers/Credentials APIs without discovery,
  sync, provider-link migration, transport building or network authorization.

  Evidence contains stable IDs, the permission fingerprint, hashed provider
  generations and hex credential versions. Its fingerprint may extend the exact
  Policy/readiness/Approval scope. `check/2` validates this canonical shape before
  strict comparison; a fingerprint is not authentication. Hosts must recapture
  before policy admission and after waits. This module does not install those
  checks in Policy, Approval, SessionAdapter or Worker.

  Permission validation reuses PermissionSnapshot and does not replace its exact
  tool-binding compiler. Provider availability includes its existing current
  managed-source checks; it does not prove MCP discovery or tools readiness.
  MCP/source catalog evidence is intentionally absent: there is no public pure
  live-discovery revision accessor. Version success alone is not availability.
  Sampling across stores is not atomic; hashes are content identities, not
  monotonic generations, ABA detection or proof of remote authorization. OAuth
  material and provider configuration outside authentication_generation are not
  independently fingerprinted. No secret-bearing record enters evidence/errors.
  Persisted provider validation covers only ID, name, type, enabled, config,
  base URL and credential reference; unsupported fields are not validated.
  """

  alias Synapsis.Agent.Tools.PermissionSnapshot
  alias Synapsis.{Credentials, ProviderConfig, Providers, Session.Store}
  alias Synapsis.Config.Store, as: ConfigStore

  @reader_keys [:credential, :permission, :provider]
  @evidence_keys [:credentials, :fingerprint, :permission_fingerprint, :providers, :session_id]
  @provider_fields ~w(id name type enabled config base_url credential_id)

  @spec capture(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def capture(session_id, dependencies, readers \\ default_readers()) do
    with :ok <- require_valid(nonempty?(session_id), :invalid_session),
         :ok <- require_valid(valid_dependencies?(dependencies), :invalid_dependencies),
         :ok <- require_valid(valid_readers?(readers), :invalid_readers),
         {:ok, raw} <- read(readers, :permission, session_id),
         :ok <- validate_permission(raw, session_id),
         {:ok, providers} <- capture_dependencies(readers, :provider, dependencies.provider_ids),
         {:ok, credentials} <-
           capture_dependencies(readers, :credential, dependencies.credential_ids) do
      evidence = %{
        session_id: session_id,
        permission_fingerprint: PermissionSnapshot.fingerprint(raw),
        providers: providers,
        credentials: credentials
      }

      {:ok, Map.put(evidence, :fingerprint, digest(evidence))}
    end
  end

  @spec check(term(), term()) :: :ok | {:error, :invalid_evidence | :freshness_changed}
  def check(expected, current) do
    cond do
      not valid_evidence?(expected) or not valid_evidence?(current) -> {:error, :invalid_evidence}
      expected === current -> :ok
      true -> {:error, :freshness_changed}
    end
  end

  @doc "Trusted local readers; successful results never contain resolved secrets."
  def default_readers do
    %{
      permission: fn id ->
        case Store.get_value(id, "permission", :freshness_permission_unavailable) do
          :freshness_permission_unavailable -> {:error, :unavailable}
          raw -> {:ok, raw}
        end
      end,
      provider: &read_provider/1,
      credential: fn id ->
        with {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 <-
               Credentials.resolve(id),
             {:ok, version} <- Credentials.version(id) do
          {:ok, version}
        end
      end
    }
  end

  defp read_provider(id) do
    with {:ok, %{"id" => ^id} = raw} <- ConfigStore.get(:provider, id),
         true <-
           ProviderConfig.changeset(%ProviderConfig{}, Map.take(raw, @provider_fields)).valid?,
         {:ok, %ProviderConfig{id: ^id} = provider} <- Providers.get(id),
         true <- is_map(provider.config) and not is_struct(provider.config),
         true <- Providers.runtime_available?(provider) do
      {:ok, Providers.authentication_generation(provider)}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp capture_dependencies(readers, kind, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, result} ->
      with {:ok, value} <- read(readers, kind, id),
           true <- valid_value?(kind, id, value) do
        fingerprint =
          if kind == :credential, do: Base.encode16(value, case: :lower), else: digest(value)

        {:cont, {:ok, Map.put(result, id, fingerprint)}}
      else
        _ -> {:halt, {:error, unavailable(kind, id)}}
      end
    end)
  end

  defp read(readers, kind, id) do
    case Map.fetch!(readers, kind).(id) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, unavailable(kind, id)}
    end
  rescue
    _ -> {:error, unavailable(kind, id)}
  catch
    _, _ -> {:error, unavailable(kind, id)}
  end

  defp unavailable(:permission, _), do: :permission_unavailable
  defp unavailable(:provider, id), do: {:provider_unavailable, id}
  defp unavailable(:credential, id), do: {:credential_unavailable, id}

  defp validate_permission(raw, session_id) do
    case PermissionSnapshot.validate(raw, session_id) do
      :ok -> :ok
      {:needs_review, :session_mismatch} -> {:error, :session_mismatch}
      _ -> {:error, :invalid_permission_snapshot}
    end
  end

  defp valid_value?(:credential, _, version), do: is_binary(version) and byte_size(version) == 32

  defp valid_value?(:provider, id, {id, updated_at, true, base_url, credential_id, version}) do
    valid_time?(updated_at) and (is_nil(base_url) or is_binary(base_url)) and
      ((is_nil(credential_id) and is_nil(version)) or
         (nonempty?(credential_id) and
            match?({:ok, hash} when is_binary(hash) and byte_size(hash) == 32, version)))
  end

  defp valid_value?(_, _, _), do: false

  defp valid_time?(nil), do: true
  defp valid_time?(%DateTime{}), do: true

  defp valid_time?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_time?(_), do: false

  defp valid_dependencies?(dependencies)
       when is_map(dependencies) and not is_struct(dependencies) do
    Enum.sort(Map.keys(dependencies)) == [:credential_ids, :provider_ids] and
      Enum.all?(Map.values(dependencies), fn ids ->
        is_list(ids) and Enum.all?(ids, &nonempty?/1) and length(ids) == length(Enum.uniq(ids))
      end)
  end

  defp valid_dependencies?(_), do: false

  defp valid_readers?(readers) when is_map(readers) and not is_struct(readers),
    do:
      Enum.sort(Map.keys(readers)) == @reader_keys and
        Enum.all?(Map.values(readers), &is_function(&1, 1))

  defp valid_readers?(_), do: false

  defp valid_evidence?(evidence) when is_map(evidence) and not is_struct(evidence) do
    Enum.sort(Map.keys(evidence)) == @evidence_keys and nonempty?(evidence.session_id) and
      hash?(evidence.permission_fingerprint) and valid_fingerprints?(evidence.providers) and
      valid_fingerprints?(evidence.credentials) and hash?(evidence.fingerprint) and
      evidence.fingerprint === digest(Map.delete(evidence, :fingerprint))
  end

  defp valid_evidence?(_), do: false

  defp valid_fingerprints?(values) when is_map(values) and not is_struct(values),
    do: Enum.all?(values, fn {id, value} -> nonempty?(id) and hash?(value) end)

  defp valid_fingerprints?(_), do: false

  defp hash?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp require_valid(true, _), do: :ok
  defp require_valid(false, reason), do: {:error, reason}

  defp digest(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
end
