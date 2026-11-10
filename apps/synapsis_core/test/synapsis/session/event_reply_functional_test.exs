defmodule Synapsis.Session.EventReplyFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.{Message, Part}
  alias Synapsis.Session.EventReply

  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/event-reply.json",
             __DIR__
           )
  @external_resource @fixture
  @capture @fixture |> File.read!() |> Jason.decode!()

  test "message helper matches all eighteen actual original whole-module observations" do
    assert @capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(@capture["observations"]) == 18

    for row <- @capture["observations"] do
      result = row["actual"]

      assert EventReply.strip_heartbeat_token(row["raw"]) ==
               %{
                 text: result["text"],
                 did_strip: result["didStrip"],
                 should_skip: result["shouldSkip"]
               },
             row["id"]
    end
  end

  test "token-free display wrapper preserves formatting while helper uses ECMAScript trim" do
    raw = "\uFEFF  Ordinary\n\nanswer\t\u00A0"
    assert EventReply.text(raw) == raw

    assert EventReply.strip_heartbeat_token(raw) ==
             %{text: "Ordinary\n\nanswer", did_strip: false, should_skip: false}

    assert EventReply.strip_heartbeat_token("\uFEFF \t") ==
             %{text: "", did_strip: false, should_skip: true}

    assert EventReply.text("HEARTBEAT_OK \u0085") == "\u0085"
    assert EventReply.text("HEARTBEAT_OK \u180E") == "\u180E"
  end

  test "message presentation retains meaningful long remainder without heartbeat quiet suppression" do
    body = String.duplicate("完成", 170)
    assert EventReply.text("HEARTBEAT_OK " <> body) == body

    assert EventReply.strip_heartbeat_token("HEARTBEAT_OK " <> body) ==
             %{text: body, did_strip: true, should_skip: false}

    assert EventReply.text("HEARTBEAT_OK First line\n\nSecond line") == "First line Second line"
  end

  test "tagged assistant text parts project independently and retain reasoning media and tool values" do
    occurrence = Ecto.UUID.generate()
    stamp = %{"version" => 1, "policy" => "manual_event_message", "occurrence_id" => occurrence}
    assert EventReply.stamp(occurrence) == stamp
    reasoning = %Part.Reasoning{content: "HEARTBEAT_OK internal reasoning"}
    image = %Part.Image{media_type: "image/png", data: "unchanged-image-bytes", path: "image.png"}

    tool = %Part.ToolResult{
      tool_use_id: "tool1",
      content: "HEARTBEAT_OK nested value",
      projection: %{"text" => "HEARTBEAT_OK nested projection"}
    }

    message =
      %Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        parts: [
          %Part.Text{content: "HEARTBEAT_OK"},
          reasoning,
          %Part.Text{content: "All done HEARTBEAT_OK"},
          image,
          tool
        ]
      }
      |> Map.put(:reply_presentation, stamp)

    original = Message.encode(message)

    assert EventReply.project(message) == %{
             version: 1,
             policy: "manual_event_message",
             occurrence_id: occurrence,
             hidden: false,
             text: "All done",
             text_parts: [%{index: 0, text: ""}, %{index: 2, text: "All done"}]
           }

    displayed = EventReply.display_message(message)

    assert displayed.parts == [
             %Part.Text{content: ""},
             reasoning,
             %Part.Text{content: "All done"},
             image,
             tool
           ]

    assert displayed.id == message.id
    assert Map.get(displayed, :reply_presentation) == stamp
    assert Message.encode(message) == original

    assert message.parts == [
             %Part.Text{content: "HEARTBEAT_OK"},
             reasoning,
             %Part.Text{content: "All done HEARTBEAT_OK"},
             image,
             tool
           ]

    assert EventReply.project(%{message | role: :assistant}) == EventReply.project(message)
  end

  test "marker-only event text hides a row while marker captions retain their typed media" do
    occurrence = Ecto.UUID.generate()

    message =
      %Message{role: "assistant", parts: [%Part.Text{content: "HEARTBEAT_OK"}]}
      |> Map.put(:reply_presentation, EventReply.stamp(occurrence))

    assert %{hidden: true, text: "", text_parts: [%{index: 0, text: ""}]} =
             EventReply.project(message)

    assert EventReply.display_message(message) == nil
    media = %Part.File{path: "report.txt", content: "HEARTBEAT_OK report"}
    with_media = %{message | parts: message.parts ++ [media]}
    assert %{hidden: false, text: ""} = EventReply.project(with_media)
    assert EventReply.display_message(with_media).parts == [%Part.Text{content: ""}, media]
  end

  test "ordinary authored marker text keeps its raw visible representation" do
    message = %Message{role: "assistant", parts: [%Part.Text{content: "HEARTBEAT_OK ordinary"}]}
    assert EventReply.project(message) == nil
    assert EventReply.display_message(message) == message
  end
end
