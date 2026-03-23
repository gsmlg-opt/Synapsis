defmodule Synapsis.Session.DebugTelemetry do
  @moduledoc """
  Attaches telemetry handlers for a single agent turn when debug mode is enabled.
  Writes sanitized request/response to Debug.Store (ETS) and broadcasts via PubSub.
  """

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
        Synapsis.Debug.Store.put_request(config.session_id, sanitized)
      end

      # Normalize to atom keys for consistent access downstream
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "debug:#{config.session_id}",
        {"debug_request", sanitized}
      )
    end
  end

  def handle_event(@response_event, measurements, metadata, config) do
    if metadata.session_id == config.session_id do
      sanitized = SynapsisProvider.Sanitizer.sanitize_response(metadata, measurements)

      if store_available?() do
        Synapsis.Debug.Store.put_response(config.session_id, sanitized)
      end

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "debug:#{config.session_id}",
        {"debug_response", sanitized}
      )
    end
  end

  defp store_available? do
    Synapsis.Debug.Store.available?()
  end
end
