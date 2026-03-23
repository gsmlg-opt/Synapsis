defmodule Synapsis.Session.DebugTelemetry do
  @moduledoc """
  Attaches telemetry handlers for a single agent turn when debug mode is enabled.
  Writes sanitized request/response to DebugStore (ETS) and broadcasts via PubSub.
  """

  # DebugStore lives in synapsis_server (compiled after synapsis_agent)
  @compile {:no_warn_undefined, SynapsisServer.DebugStore}

  @request_event [:synapsis, :provider, :request]
  @response_event [:synapsis, :provider, :response]

  @spec attach(String.t()) :: String.t()
  def attach(session_id) do
    handler_id = "debug-#{session_id}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [@request_event, @response_event],
      &handle_event/4,
      %{session_id: session_id, handler_id: handler_id}
    )

    handler_id
  end

  @spec detach(String.t()) :: :ok
  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  def handle_event(@request_event, _measurements, metadata, config) do
    if metadata.session_id == config.session_id do
      sanitized = SynapsisProvider.Sanitizer.sanitize_request(metadata)

      if store_available?() do
        SynapsisServer.DebugStore.put_request(config.session_id, sanitized)
      end

      serialized = serialize_for_channel(sanitized)

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{config.session_id}",
        {"debug_request", serialized}
      )

      # Also broadcast to LiveView subscribers
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "debug:#{config.session_id}",
        {"debug_request", serialized}
      )
    end
  end

  def handle_event(@response_event, measurements, metadata, config) do
    if metadata.session_id == config.session_id do
      sanitized = SynapsisProvider.Sanitizer.sanitize_response(metadata, measurements)

      if store_available?() do
        SynapsisServer.DebugStore.put_response(config.session_id, sanitized)
      end

      serialized = serialize_for_channel(sanitized)

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{config.session_id}",
        {"debug_response", serialized}
      )

      # Also broadcast to LiveView subscribers
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "debug:#{config.session_id}",
        {"debug_response", serialized}
      )
    end
  end

  defp store_available? do
    Code.ensure_loaded?(SynapsisServer.DebugStore) and
      Process.whereis(SynapsisServer.DebugStore) != nil
  end

  defp serialize_for_channel(map) do
    map
    |> Enum.map(fn
      {k, %DateTime{} = v} -> {to_string(k), DateTime.to_iso8601(v)}
      {k, v} when is_atom(v) -> {to_string(k), to_string(v)}
      {k, v} -> {to_string(k), v}
    end)
    |> Map.new()
  end
end
