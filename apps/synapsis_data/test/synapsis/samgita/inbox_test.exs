defmodule Synapsis.Samgita.InboxTest do
  use Synapsis.DataCase

  alias Synapsis.Samgita.Inbox

  @event %{
    "schema_version" => "1.0",
    "event_id" => "evt-1",
    "delivery_attempt_id" => "att-1",
    "created_at" => "2026-11-12T00:00:00Z",
    "correlation_id" => "c-1",
    "type" => "task.updated",
    "project_ref" => "p-1",
    "payload" => %{"sequence" => 1}
  }

  setup do
    clear_coord("coord/samgita/inbox/")
    on_exit(fn -> clear_coord("coord/samgita/inbox/") end)
    :ok
  end

  test "record/1 stores a new event durably as pending" do
    assert {:ok, :new, entry} = Inbox.record(@event)
    assert entry["acceptance"] == "durable"
    assert entry["processing_status"] == "pending"
    assert entry["last_delivery_attempt_id"] == "att-1"
    refute Map.has_key?(entry["event"], "delivery_attempt_id")
    assert {:ok, ^entry} = Inbox.get("evt-1")
  end

  test "a redelivery with a new attempt id is a duplicate of the same entry" do
    {:ok, :new, _} = Inbox.record(@event)

    assert {:ok, :duplicate, entry} = Inbox.record(%{@event | "delivery_attempt_id" => "att-2"})
    assert entry["last_delivery_attempt_id"] == "att-2"
    assert length(Inbox.list(10)) == 1
  end

  test "the same event id with different content is a conflict" do
    {:ok, :new, _} = Inbox.record(@event)

    assert {:error, :conflict} = Inbox.record(put_in(@event, ["payload", "sequence"], 2))
    assert {:ok, %{"event" => %{"payload" => %{"sequence" => 1}}}} = Inbox.get("evt-1")
  end

  test "mark_processed/2 completes the entry with a note" do
    {:ok, :new, _} = Inbox.record(@event)

    assert {:ok, %{"processing_status" => "completed", "note" => "noted"}} =
             Inbox.mark_processed("evt-1", "noted")

    assert {:ok, %{"processing_status" => "completed"}} = Inbox.get("evt-1")
    assert {:error, :not_found} = Inbox.mark_processed("missing", "x")
  end

  test "record_report/2 is idempotent for identical reports and rejects different ones" do
    {:ok, :new, _} = Inbox.record(@event)
    report = %{"decision_id" => "d-1", "status" => "rejected", "decision" => %{"why" => "x"}}

    assert {:ok, entry} = Inbox.record_report("evt-1", report)
    assert entry["processing_status"] == "rejected"
    assert entry["decision_id"] == "d-1"
    assert {:ok, ^entry} = Inbox.record_report("evt-1", report)
    assert {:error, :conflict} = Inbox.record_report("evt-1", %{report | "decision_id" => "d-2"})
    assert {:error, :not_found} = Inbox.record_report("missing", report)
  end

  test "list/1 returns newest first" do
    {:ok, :new, _} = Inbox.record(@event)
    Process.sleep(2)
    {:ok, :new, _} = Inbox.record(%{@event | "event_id" => "evt-2"})

    assert ["evt-2", "evt-1"] = Enum.map(Inbox.list(10), & &1["event"]["event_id"])
    assert [_] = Inbox.list(1)
  end

  test "list/1 reads only the newest entries through the received_at index" do
    for n <- 1..5 do
      {:ok, :new, _} = Inbox.record(%{@event | "event_id" => "evt-#{n}"})
      Process.sleep(2)
    end

    assert {:ok, index, _} =
             Concord.Turso.list(prefix: "coord/samgita/inbox/~at/", keys_only: true)

    assert length(index) == 5
    assert ["evt-5", "evt-4"] = Enum.map(Inbox.list(2), & &1["event"]["event_id"])
  end

  test "entries stored before the index existed are indexed on first list" do
    legacy = %{
      "event" => Map.delete(%{@event | "event_id" => "evt-old"}, "delivery_attempt_id"),
      "acceptance" => "durable",
      "processing_status" => "pending",
      "received_at" => "2026-01-01T00:00:00.000000Z",
      "updated_at" => "2026-01-01T00:00:00.000000Z"
    }

    key = "coord/samgita/inbox/" <> Base.url_encode64("evt-old", padding: false)
    :ok = Concord.Turso.put(key, legacy)
    {:ok, :new, _} = Inbox.record(@event)

    assert ["evt-1", "evt-old"] = Enum.map(Inbox.list(10), & &1["event"]["event_id"])
    assert {:ok, :duplicate, _} = Inbox.record(@event)
  end
end
