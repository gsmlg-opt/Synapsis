defmodule Synapsis.Agent.Events.RunEventTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Events.RunEvent

  test "builds a validated session.completed event" do
    assert {:ok, event} =
             RunEvent.build("session.completed",
               session_id: "sess-1",
               payload: %{"status" => "idle"}
             )

    assert event.type == "session.completed"
    assert event.session_id == "sess-1"
    assert event.schema_version == RunEvent.schema_version()
    assert is_binary(event.event_id)
    assert %DateTime{} = event.occurred_at
    assert RunEvent.session_terminal?(event)
  end

  test "rejects unknown types" do
    assert {:error, :unknown_type} = RunEvent.build("session.bogus", session_id: "s")
  end

  test "requires session_id or run_id" do
    assert {:error, :missing_session_or_run} = RunEvent.build("session.failed", payload: %{})
  end

  test "round-trips through to_map/from_map" do
    event =
      RunEvent.new("session.failed",
        session_id: "sess-2",
        run_id: "run-9",
        payload: %{"message" => "boom"}
      )

    assert {:ok, restored} =
             event
             |> RunEvent.to_map()
             |> Jason.encode!()
             |> Jason.decode!()
             |> RunEvent.from_map()

    assert restored.type == event.type
    assert restored.session_id == event.session_id
    assert restored.run_id == event.run_id
    assert restored.payload["message"] == "boom"
    assert restored.event_id == event.event_id
  end

  test "turn_completed is not a session terminal" do
    event = RunEvent.new("session.turn_completed", session_id: "sess-3")
    assert RunEvent.turn_complete?(event)
    refute RunEvent.session_terminal?(event)
  end
end
