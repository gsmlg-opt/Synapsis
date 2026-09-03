defmodule Synapsis.Tool.Capability.Grant do
  @moduledoc """
  Opaque capability grant required by `Synapsis.Tool.Gateway` before effects run.

  Grants are minted only by the policy/gateway layer and validated by MAC.
  Callers cannot assert approval by inventing a boolean flag alone.
  """

  @enforce_keys [
    :id,
    :tool_name,
    :permission_level,
    :source,
    :issued_at,
    :expires_at,
    :mac
  ]
  defstruct [
    :id,
    :tool_name,
    :permission_level,
    :source,
    :session_id,
    :run_id,
    :issued_at,
    :expires_at,
    :mac,
    argument_digest: nil
  ]

  @type source :: :policy_allow | :operator_approval | :persistent_approval
  @type t :: %__MODULE__{
          id: String.t(),
          tool_name: String.t(),
          permission_level: atom(),
          source: source(),
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          mac: binary(),
          argument_digest: binary() | nil
        }

  @default_ttl_ms 120_000

  @doc false
  @spec mint(keyword()) :: t()
  def mint(attrs) when is_list(attrs) do
    now = DateTime.utc_now()
    ttl = Keyword.get(attrs, :ttl_ms, @default_ttl_ms)

    grant = %__MODULE__{
      id: Ecto.UUID.generate(),
      tool_name: Keyword.fetch!(attrs, :tool_name),
      permission_level: Keyword.fetch!(attrs, :permission_level),
      source: Keyword.fetch!(attrs, :source),
      session_id: Keyword.get(attrs, :session_id),
      run_id: Keyword.get(attrs, :run_id),
      issued_at: now,
      expires_at: DateTime.add(now, ttl, :millisecond),
      argument_digest: digest_args(Keyword.get(attrs, :input)),
      mac: <<>>
    }

    %{grant | mac: compute_mac(grant)}
  end

  @doc "Validate grant scope, expiry, and integrity for a tool invocation."
  @spec validate(t(), String.t(), map()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = grant, tool_name, context) when is_binary(tool_name) do
    session_id = context[:session_id]
    run_id = context[:run_id]
    input = context[:input] || context["input"]

    cond do
      grant.mac != compute_mac(grant) ->
        {:error, :forged_grant}

      grant.tool_name != tool_name ->
        {:error, :grant_tool_mismatch}

      expired?(grant) ->
        {:error, :expired_grant}

      is_binary(grant.session_id) and is_binary(session_id) and grant.session_id != session_id ->
        {:error, :grant_session_mismatch}

      is_binary(grant.run_id) and is_binary(run_id) and grant.run_id != run_id ->
        {:error, :grant_run_mismatch}

      grant.argument_digest && input && grant.argument_digest != digest_args(input) ->
        {:error, :grant_argument_mismatch}

      true ->
        :ok
    end
  end

  def validate(_, _, _), do: {:error, :invalid_grant}

  defp expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp digest_args(nil), do: nil

  defp digest_args(input) when is_map(input) do
    :crypto.hash(:sha256, :erlang.term_to_binary(normalize(input)))
  end

  defp digest_args(input), do: :crypto.hash(:sha256, :erlang.term_to_binary(input))

  defp normalize(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), normalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  defp compute_mac(%__MODULE__{} = grant) do
    payload = {
      grant.id,
      grant.tool_name,
      grant.permission_level,
      grant.source,
      grant.session_id,
      grant.run_id,
      DateTime.to_iso8601(grant.issued_at),
      DateTime.to_iso8601(grant.expires_at),
      grant.argument_digest
    }

    :crypto.mac(:hmac, :sha256, signing_secret(), :erlang.term_to_binary(payload))
  end

  defp signing_secret do
    Application.get_env(:synapsis_core, :capability_grant_secret) ||
      Application.get_env(:synapsis_data, :encryption_key) ||
      "synapsis-capability-grant-dev-secret"
  end
end
