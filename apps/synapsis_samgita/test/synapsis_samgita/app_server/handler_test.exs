defmodule SynapsisSamgita.AppServer.HandlerTest do
  use ExUnit.Case, async: false

  alias SamgitaProtocol.Server
  alias Synapsis.Samgita.Inbox
  alias SynapsisSamgita.AppServer.Handler

  @event %{
    "schema_version" => "1.0",
    "event_id" => "evt-h1",
    "delivery_attempt_id" => "att-1",
    "created_at" => "2026-11-12T00:00:00Z",
    "correlation_id" => "c-1",
    "type" => "task.updated",
    "project_ref" => "p-1",
    "payload" => %{"sequence" => 1}
  }

  setup do
    Synapsis.DataCase.clear_coord("coord/samgita/inbox/")
    on_exit(fn -> Synapsis.DataCase.clear_coord("coord/samgita/inbox/") end)
    {:ok, server} = Server.new(Handler, nil)

    {:ok, [init], server} =
      Server.receive(
        server,
        request("init", "connection/initialize", %{
          "versions" => ["1.0"],
          "capabilities" => ["project_events.v1"],
          "required_capabilities" => ["project_events.v1"]
        })
      )

    %{server: server, init: init}
  end

  test "initialize negotiates project_events.v1 only", %{init: init} do
    assert init["result"]["capabilities"] == ["project_events.v1"]
    assert init["result"]["version"] == "1.0"
  end

  test "receive stores the event durably and echoes the attempt id", %{server: server} do
    SynapsisSamgita.Events.subscribe()
    {result, _server} = call(server, "project/event.receive", %{"event" => @event}, "cmd-1")

    assert %{
             "event_id" => "evt-h1",
             "delivery_attempt_id" => "att-1",
             "acceptance" => "durable",
             "processing_status" => "pending"
           } = result

    assert_receive {:samgita_inbox_changed, "evt-h1"}
  end

  test "a redelivery echoes the new attempt id and keeps one entry", %{server: server} do
    {_, server} = call(server, "project/event.receive", %{"event" => @event}, "cmd-1")
    event2 = %{@event | "delivery_attempt_id" => "att-2"}
    {result, _} = call(server, "project/event.receive", %{"event" => event2}, "cmd-2")

    assert result["delivery_attempt_id"] == "att-2"
    assert length(Inbox.list(10)) == 1
  end

  test "conflicting content under the same event id is a conflict error", %{server: server} do
    {_, server} = call(server, "project/event.receive", %{"event" => @event}, "cmd-1")
    changed = put_in(@event, ["payload", "sequence"], 2)
    {response, _} = raw_call(server, "project/event.receive", %{"event" => changed}, "cmd-2")

    assert response["error"]["code"] == "conflict"
  end

  test "status reports not_found, then the operator's completion", %{server: server} do
    {response, server} = raw_call(server, "project/event.status", %{"event_id" => "evt-h1"}, nil)
    assert response["error"]["code"] == "not_found"

    {_, server} = call(server, "project/event.receive", %{"event" => @event}, "cmd-1")
    {:ok, _} = Inbox.mark_processed("evt-h1", "noted")
    {result, _} = call(server, "project/event.status", %{"event_id" => "evt-h1"}, nil)

    assert %{"acceptance" => "durable", "processing_status" => "completed"} = result
  end

  test "report is recorded and visible through status", %{server: server} do
    {_, server} = call(server, "project/event.receive", %{"event" => @event}, "cmd-1")

    report = %{
      "event_id" => "evt-h1",
      "decision_id" => "d-1",
      "status" => "completed",
      "decision" => %{"summary" => "ok"}
    }

    {result, server} = call(server, "project/event.report", report, "cmd-2")

    assert %{"report_status" => "recorded", "management_acceptance" => "not_requested"} = result
    {status, _} = call(server, "project/event.status", %{"event_id" => "evt-h1"}, nil)
    assert status["decision_id"] == "d-1"
    assert status["processing_status"] == "completed"
  end

  defp call(server, method, params, command_id) do
    {response, server} = raw_call(server, method, params, command_id)
    assert Map.has_key?(response, "result"), inspect(response)
    {response["result"], server}
  end

  defp raw_call(server, method, params, command_id) do
    id = "req-#{System.unique_integer([:positive])}"
    message = request(id, method, params)
    message = if command_id, do: Map.put(message, "command_id", command_id), else: message
    {:ok, [response], server} = Server.receive(server, message)
    {response, server}
  end

  defp request(id, method, params) do
    %{
      "schema_version" => "1.0",
      "type" => "request",
      "id" => id,
      "correlation_id" => "corr-#{id}",
      "method" => method,
      "params" => params
    }
  end
end
