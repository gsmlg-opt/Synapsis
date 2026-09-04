defmodule Synapsis.Backplane.Events do
  @moduledoc "Publishes bounded Backplane lifecycle envelopes on the agent daemon topic."

  require Logger

  alias Synapsis.Backplane.Connection

  @topic "agent:daemon"
  @max_string_bytes 500
  @max_collection_entries 100
  @max_depth 5
  @sensitive_keys ~w(authorization credential api_key api_key_encrypted token access_token)

  def started(%Connection{} = connection),
    do: publish("backplane.sync.started", connection, %{status: "syncing"})

  def completed(%Connection{} = connection),
    do: publish("backplane.sync.completed", connection, connection_payload(connection))

  def failed(%Connection{} = connection),
    do: publish("backplane.sync.failed", connection, connection_payload(connection))

  def capabilities_updated(%Connection{} = connection),
    do: publish("backplane.capabilities.updated", connection, connection_payload(connection))

  defp publish(event, connection, payload) do
    envelope =
      payload
      |> Map.merge(%{
        event: event,
        connection_id: connection.id,
        at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
      |> sanitize(connection.credential, 0)

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event, envelope}
    )

    :ok
  rescue
    error ->
      Logger.warning("backplane_event_publish_failed",
        event: event,
        connection_id: connection.id,
        reason: error.__struct__
      )

      :ok
  end

  defp connection_payload(connection) do
    %{
      status: connection.status,
      counts: connection.counts,
      unavailable: connection.unavailable,
      source_revision: connection.source_revision,
      error: connection.last_error
    }
  end

  defp sanitize(_value, _credential, depth) when depth >= @max_depth, do: "[TRUNCATED]"

  defp sanitize(value, credential, _depth) when is_binary(value) do
    value
    |> valid_utf8()
    |> redact_credential(credential)
    |> truncate_binary()
  end

  defp sanitize(value, credential, depth) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key) end)
    |> Enum.take(@max_collection_entries)
    |> Enum.reduce({%{}, MapSet.new()}, fn {key, nested}, {sanitized, used_keys} ->
      key = sanitize_key(key, credential, depth)
      sensitive? = sensitive_key?(key)
      {key, used_keys} = unique_key(key, used_keys)

      nested =
        if sensitive?,
          do: "[REDACTED]",
          else: sanitize(nested, credential, depth + 1)

      {Map.put(sanitized, key, nested), used_keys}
    end)
    |> elem(0)
  end

  defp sanitize(value, credential, depth) when is_list(value) do
    value
    |> Enum.take(@max_collection_entries)
    |> Enum.map(&sanitize(&1, credential, depth + 1))
  end

  defp sanitize(value, _credential, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: value

  defp sanitize(value, credential, depth),
    do: value |> inspect() |> sanitize(credential, depth + 1)

  defp redact_credential(value, credential) when is_binary(credential) and credential != "",
    do: String.replace(value, credential, "[REDACTED]")

  defp redact_credential(value, _credential), do: value

  defp truncate_binary(value) when byte_size(value) <= @max_string_bytes, do: value

  defp truncate_binary(value) do
    value
    |> binary_part(0, @max_string_bytes)
    |> :unicode.characters_to_binary()
    |> case do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end

  defp sanitize_key(key, credential, _depth) when is_binary(key),
    do: sanitize(key, credential, 0)

  defp sanitize_key(key, _credential, _depth) when is_atom(key), do: key
  defp sanitize_key(key, credential, depth), do: sanitize(inspect(key), credential, depth + 1)

  defp unique_key(key, used_keys) do
    identity = key_identity(key)

    if MapSet.member?(used_keys, identity) do
      unique_key_with_suffix(key, used_keys, 2)
    else
      {key, MapSet.put(used_keys, identity)}
    end
  end

  defp unique_key_with_suffix(key, used_keys, index) do
    suffix = "##{index}"
    base = key |> to_string() |> truncate_to_bytes(@max_string_bytes - byte_size(suffix))
    candidate = base <> suffix
    identity = key_identity(candidate)

    if MapSet.member?(used_keys, identity),
      do: unique_key_with_suffix(key, used_keys, index + 1),
      else: {candidate, MapSet.put(used_keys, identity)}
  end

  defp key_identity(key) when is_atom(key) or is_binary(key), do: to_string(key)
  defp key_identity(key), do: inspect(key)

  defp truncate_to_bytes(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate_to_bytes(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> valid_utf8()
  end

  defp valid_utf8(value) do
    value
    |> valid_utf8_chunks()
    |> IO.iodata_to_binary()
  end

  defp valid_utf8_chunks(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      valid when is_binary(valid) ->
        valid

      {:error, valid, <<_invalid, rest::binary>>} ->
        [valid, "�", valid_utf8_chunks(rest)]

      {:incomplete, valid, _rest} ->
        [valid, "�"]
    end
  end

  defp sensitive_key?(key), do: String.downcase(to_string(key)) in @sensitive_keys
end
