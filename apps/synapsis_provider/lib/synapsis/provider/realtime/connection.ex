defmodule Synapsis.Provider.Realtime.Connection do
  @moduledoc "Bounded, acknowledged WebSocket transport for the host's persistent Realtime connection."

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event.{Close, Error, Frame, Open}

  def open(%{websocket_url: url, headers: headers}, model) do
    uri = %{URI.parse(url) | query: URI.encode_query(%{"model" => model})}

    case WebSocket.new(URI.to_string(uri), [],
           headers: headers,
           mode: :proxy,
           http_version: :http1,
           delivery: :ack,
           opening_timeout: 5_000,
           write_timeout: 2_000,
           close_timeout: 1_000,
           idle_timeout: 300_000,
           max_message_size: 2_097_152,
           max_frame_bytes: 2_097_152,
           max_queue_bytes: 4_194_304,
           max_queue_events: 16
         ) do
      %WebSocket{} = socket -> {:ok, socket}
      _ -> {:error, :realtime_connect_failed}
    end
  end

  def send_event(socket, body), do: WebSocket.send_ack(socket, JSON.encode!(body))
  def close(socket), do: WebSocket.close(socket)

  def receive_event({WebSocket, socket, %Open{}}, socket), do: :open

  def receive_event({WebSocket, socket, %Frame{opcode: :text, data: data}, receipt}, socket) do
    case JSON.decode(data) do
      {:ok, %{"type" => _} = event} -> {:event, event, receipt}
      _ -> {:error, :invalid_realtime_event}
    end
  end

  def receive_event({WebSocket, socket, %Frame{}, receipt}, socket) do
    acknowledge(socket, receipt)
    :ignore
  end

  def receive_event({WebSocket, socket, %Close{code: code}}, socket) do
    reason =
      case code do
        # TODO(upstream): gsmlg-opt/backplane#185 — Revalidate anonymous Realtime admission.
        1008 -> :realtime_policy_rejected
        1009 -> :realtime_budget_exceeded
        _ -> :realtime_disconnected
      end

    {:error, reason}
  end

  def receive_event({WebSocket, socket, %Error{handshake: %{status: status}}}, socket)
      when status in [400, 401, 403, 404] do
    reason =
      case status do
        400 -> :realtime_model_rejected
        401 -> :realtime_unauthorized
        403 -> :realtime_forbidden
        404 -> :realtime_not_configured
      end

    {:error, reason}
  end

  def receive_event({WebSocket, socket, %Error{}}, socket), do: {:error, :realtime_disconnected}

  def receive_event({WebSocket, socket, {:send_result, ref, :ok}}, socket),
    do: {:sent, ref}

  def receive_event({WebSocket, socket, {:send_result, _ref, {:error, _}}}, socket),
    do: {:error, :realtime_write_failed}

  def receive_event(_, _), do: :ignore

  def acknowledge(socket, receipt), do: WebSocket.acknowledge(socket, receipt)
  def owner(%WebSocket{pid: pid}), do: pid
end
