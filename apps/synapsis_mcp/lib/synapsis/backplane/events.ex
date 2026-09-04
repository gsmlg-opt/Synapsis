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
    |> redact_credential(credential)
    |> truncate_binary()
  end

  defp sanitize(value, credential, depth) when is_map(value) do
    value
    |> Enum.take(@max_collection_entries)
    |> Map.new(fn {key, nested} ->
      if sensitive_key?(key),
        do: {key, "[REDACTED]"},
        else: {key, sanitize(nested, credential, depth + 1)}
    end)
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

  defp sensitive_key?(key), do: String.downcase(to_string(key)) in @sensitive_keys
end
