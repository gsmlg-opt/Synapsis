defmodule SynapsisSamgita.AppServer.Handler do
  @moduledoc """
  samgita_protocol host for `project_events.v1`.

  Events are committed to `Synapsis.Samgita.Inbox` before the result is returned,
  so `acceptance` is always `"durable"`. Processing is operator-driven this phase:
  entries stay `pending` until marked processed or reported.
  """
  @behaviour SamgitaProtocol.Handler

  require Logger

  alias SamgitaProtocol.Error
  alias Synapsis.Samgita.Inbox
  alias SynapsisSamgita.Events

  @impl true
  def capabilities, do: ["project_events.v1"]

  @impl true
  def methods, do: ~w(project/event.receive project/event.report project/event.status)

  @impl true
  def handle_request("project/event.receive", %{"event" => event}, _context, state) do
    case Inbox.record(event) do
      {:ok, tag, entry} ->
        if tag == :new, do: Logger.info("samgita_event_received", event_id: event["event_id"])
        Events.broadcast_inbox_changed(event["event_id"])

        {:ok,
         %{
           "event_id" => event["event_id"],
           "delivery_attempt_id" => event["delivery_attempt_id"],
           "acceptance" => entry["acceptance"],
           "processing_status" => entry["processing_status"]
         }, state}

      error ->
        {:error, to_error(error), state}
    end
  end

  def handle_request("project/event.status", %{"event_id" => event_id}, _context, state) do
    case Inbox.get(event_id) do
      {:ok, entry} -> {:ok, status_result(event_id, entry), state}
      error -> {:error, to_error(error), state}
    end
  end

  def handle_request("project/event.report", %{"event_id" => event_id} = params, _context, state) do
    case Inbox.record_report(event_id, params) do
      {:ok, _entry} ->
        Events.broadcast_inbox_changed(event_id)

        {:ok,
         %{
           "event_id" => event_id,
           "decision_id" => params["decision_id"],
           "report_status" => "recorded",
           "management_acceptance" => "not_requested"
         }, state}

      error ->
        {:error, to_error(error), state}
    end
  end

  defp status_result(event_id, entry) do
    %{
      "event_id" => event_id,
      "acceptance" => entry["acceptance"],
      "processing_status" => entry["processing_status"]
    }
    |> put_present("decision_id", entry["decision_id"])
    |> put_present("decision", entry["decision"])
    |> put_present("result", entry["result"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp to_error({:error, :conflict}), do: Error.new("conflict")
  defp to_error({:error, :not_found}), do: Error.new("not_found")

  defp to_error({:error, reason}) do
    Logger.warning("samgita_inbox_failed", reason: inspect(reason))
    Error.new("handler_error")
  end
end
