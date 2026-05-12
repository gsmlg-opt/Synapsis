defmodule Synapsis.HarnessEventsTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{HarnessEvent, HarnessEvents}

  test "append assigns the next session version" do
    session_id = Ecto.UUID.generate()

    assert {:ok, %HarnessEvent{version: 1}} =
             HarnessEvents.append(session_id, "session_created", %{
               "project_id" => Ecto.UUID.generate()
             })

    assert {:ok, %HarnessEvent{version: 2}} =
             HarnessEvents.append(session_id, "message_appended", %{
               "message_id" => Ecto.UUID.generate()
             })
  end

  test "list_for_session returns events in version order" do
    session_id = Ecto.UUID.generate()

    {:ok, _} = HarnessEvents.append(session_id, "session_created", %{})
    {:ok, _} = HarnessEvents.append(session_id, "message_appended", %{})

    assert [%{version: 1}, %{version: 2}] = HarnessEvents.list_for_session(session_id)
  end
end
