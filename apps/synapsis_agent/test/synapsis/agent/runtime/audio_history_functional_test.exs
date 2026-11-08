defmodule Synapsis.Agent.Runtime.AudioHistoryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Session.{Snapshot, Store}
  alias Synapsis.{Message, Part}

  test "durable assistant audio remains rich while ordinary runtime history uses bounded text" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(id) end)
    audio = audio()

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: id,
      role: "assistant",
      parts: [%Part.Text{content: "before"}, audio, %Part.Text{content: "after"}]
    }

    encoded = Snapshot.encode_message(message)

    assert [
             %{type: "text", text: "before"},
             %{type: "audio", descriptor: descriptor, delivery: delivery, name: "Clip 🙂"},
             %{type: "text", text: "after"}
           ] =
             encoded.parts

    assert descriptor == audio.descriptor
    assert delivery == audio.delivery
    assert :ok = Store.commit_turn(id, 0, encoded, %{status: "idle"})
    assert {:ok, %{turns: [^encoded]}} = Snapshot.rehydrate(id)
    assert [%Message{parts: [_, ^audio, _]} = loaded] = Message.list_by_session(id)

    assert {:ok,
            [
              %{
                role: :assistant,
                content: [
                  %{type: :text, text: "before"},
                  %{type: :text, text: text},
                  %{type: :text, text: "after"}
                ]
              }
            ] = runtime} =
             ProviderMessages.from_host([loaded])

    assert text == Part.Audio.summary(audio)
    assert byte_size(text) <= 2048
    assert text =~ "synapsis-media://audio/"

    assert {:ok,
            [
              %{
                role: :assistant,
                parts: [
                  %Part.Text{content: "before"},
                  %Part.Text{content: ^text},
                  %Part.Text{content: "after"}
                ]
              }
            ]} =
             ProviderMessages.to_host(runtime)

    # Projection never rewrites the durable rich history.
    assert [%Message{parts: [_, ^audio, _]}] = Message.list_by_session(id)
  end

  test "audio summaries compose with image, video and ordinary tool history" do
    audio = audio()
    image = %Part.Image{media_type: "image/png", data: "AA=="}

    video =
      struct(Part.Video,
        descriptor: %{"uri" => "clip", "mime_type" => "video/mp4"},
        delivery: audio.delivery,
        name: "clip"
      )

    delivered =
      struct(Part.DeliveredImage,
        descriptor: %{"uri" => "picture", "mime_type" => "image/png"},
        delivery: audio.delivery,
        name: "picture"
      )

    call = %Part.ToolUse{tool_use_id: "ordinary", tool: "clock", input: %{}}
    result = %Part.ToolResult{tool_use_id: "ordinary", content: "12:00"}

    assert {:ok, [assistant, tool]} =
             ProviderMessages.from_host([
               %{role: "assistant", parts: [audio, image, video, delivered, call, result]}
             ])

    assert assistant.content == [
             %{type: :text, text: Part.Audio.summary(audio)},
             %{type: :image, media_type: "image/png", data: "AA==", path: nil},
             %{type: :text, text: Part.Video.summary(video)},
             %{type: :text, text: Part.DeliveredImage.summary(delivered)},
             %{type: :tool_call, id: "ordinary", name: "clock", arguments: %{}}
           ]

    assert tool == %{
             role: :tool,
             tool_call_id: "ordinary",
             result: %{content: "12:00", is_error: false}
           }
  end

  defp audio do
    struct(Part.Audio,
      name: "Clip 🙂",
      descriptor: %{
        "uri" => "synapsis-media://audio/" <> String.duplicate("a", 64) <> ".mp3",
        "sha256" => String.duplicate("a", 64),
        "byte_size" => 1234,
        "format" => "mp3",
        "mime_type" => "audio/mpeg"
      },
      delivery: %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      }
    )
  end
end
