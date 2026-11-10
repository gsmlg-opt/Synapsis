defmodule Synapsis.Agent.Runtime.VideoHistoryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Session.{Snapshot, Store}
  alias Synapsis.{Message, Part}

  test "durable assistant video remains rich while ordinary runtime history uses bounded text" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(id) end)
    video = video()

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: id,
      role: "assistant",
      parts: [video]
    }

    encoded = Snapshot.encode_message(message)

    assert [%{type: "video", descriptor: descriptor, delivery: delivery, name: "Clip 🙂"}] =
             encoded.parts

    assert descriptor == video.descriptor
    assert delivery == video.delivery
    assert :ok = Store.commit_turn(id, 0, encoded, %{status: "idle"})
    assert {:ok, %{turns: [^encoded]}} = Snapshot.rehydrate(id)
    assert [%Message{parts: [^video]} = loaded] = Message.list_by_session(id)

    assert {:ok, [%{role: :assistant, content: [%{type: :text, text: text}]}] = runtime} =
             ProviderMessages.from_host([loaded])

    assert text == Part.Video.summary(video)
    assert byte_size(text) <= 2048
    assert text =~ "synapsis-media://video/"

    assert {:ok, [%{role: :assistant, parts: [%Part.Text{content: ^text}]}]} =
             ProviderMessages.to_host(runtime)

    # Projection never rewrites the durable rich history.
    assert [%Message{parts: [^video]}] = Message.list_by_session(id)
  end

  defp video do
    struct(Part.Video,
      name: "Clip 🙂",
      descriptor: %{
        "uri" => "synapsis-media://video/" <> String.duplicate("a", 64) <> ".mp4",
        "sha256" => String.duplicate("a", 64),
        "byte_size" => 1234,
        "format" => "mp4",
        "mime_type" => "VIDEO/MP4; codecs=avc1"
      },
      delivery: %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      }
    )
  end
end
