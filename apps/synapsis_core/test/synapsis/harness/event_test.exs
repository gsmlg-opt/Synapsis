defmodule Synapsis.Harness.EventTest do
  use ExUnit.Case, async: true

  alias Synapsis.Harness.Event

  test "session_created carries aggregate metadata" do
    event =
      Event.session_created("session-1",
        project_id: "project-1",
        parent_id: nil,
        metadata: %{"model" => "claude"}
      )

    assert %Event.SessionCreated{
             aggregate_id: "session-1",
             version: nil,
             project_id: "project-1",
             parent_id: nil,
             metadata: %{"model" => "claude"}
           } = event
  end

  test "message_appended stores the role-tagged message payload" do
    event =
      Event.message_appended("session-1", %{
        id: "message-1",
        role: :user,
        ordinal: 0
      })

    assert %Event.MessageAppended{
             aggregate_id: "session-1",
             message: %{id: "message-1", role: :user, ordinal: 0}
           } = event
  end

  test "part_appended stores durable part identity and type" do
    event =
      Event.part_appended("session-1", "message-1", %{
        id: "part-1",
        type: :text,
        ordinal: 0,
        data: %{content: "hello"}
      })

    assert %Event.PartAppended{
             aggregate_id: "session-1",
             message_id: "message-1",
             part: %{id: "part-1", type: :text, ordinal: 0, data: %{content: "hello"}}
           } = event
  end
end
