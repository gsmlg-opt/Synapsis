defmodule Synapsis.Harness.ContextTest do
  use ExUnit.Case, async: true

  alias Synapsis.Harness.{Context, Event}

  test "folds session, messages, and parts in order" do
    events = [
      Event.session_created("session-1", project_id: "project-1"),
      Event.message_appended("session-1", %{id: "message-1", role: :user, ordinal: 0}),
      Event.part_appended("session-1", "message-1", %{
        id: "part-1",
        type: :text,
        ordinal: 0,
        data: %{content: "hello"}
      })
    ]

    context = Enum.reduce(events, Context.new(), &Context.apply_event/2)

    assert context.session_id == "session-1"
    assert context.project_id == "project-1"
    assert [%{id: "message-1", parts: [%{id: "part-1"}]}] = context.messages
  end

  test "updates a part by id" do
    context =
      Context.new()
      |> Context.apply_event(Event.session_created("session-1", project_id: "project-1"))
      |> Context.apply_event(
        Event.message_appended("session-1", %{id: "message-1", role: :assistant, ordinal: 0})
      )
      |> Context.apply_event(
        Event.part_appended("session-1", "message-1", %{
          id: "part-1",
          type: :tool,
          ordinal: 0,
          data: %{state: :pending}
        })
      )
      |> Context.apply_event(
        Event.part_updated("session-1", "message-1", "part-1", %{
          data: %{state: :running}
        })
      )

    assert [%{parts: [%{data: %{state: :running}}]}] = context.messages
  end

  test "permission and abort events update in-flight state" do
    context =
      Context.new()
      |> Context.apply_event(Event.session_created("session-1", project_id: "project-1"))
      |> Context.apply_event(Event.permission_requested("session-1", "request-1", "part-1", :write))
      |> Context.apply_event(Event.permission_denied("session-1", "request-1", :user_denied))
      |> Context.apply_event(Event.aborted("session-1", :user_requested))

    assert context.pending_permission == nil
    assert context.status == :aborted
  end
end
