defmodule Synapsis.FLACAudioPartFunctionalTest do
  use Synapsis.DataCase
  @moduletag :functional

  alias Synapsis.{Message, Part}
  alias Synapsis.Session.Store

  for {format, mime} <- [
        {"mp3", "audio/mpeg"},
        {"opus", "audio/ogg"},
        {"flac", "audio/flac"},
        {"wav", "audio/wav"},
        {"pcm", "application/octet-stream"}
      ] do
    @format format
    @mime mime

    test "#{format} Audio and Message preserve generic public fields through JSON and Concord" do
      bytes = <<0, 255, 128, "opaque audio history", 0>>
      sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      id = Ecto.UUID.generate()
      on_exit(fn -> Store.delete_session(id) end)

      descriptor = %{
        "uri" => "synapsis-media://audio/#{sha}.#{@format}",
        "sha256" => sha,
        "byte_size" => byte_size(bytes),
        "format" => @format,
        "mime_type" => @mime
      }

      delivery = %{"version" => 1, "session_id" => id, "id" => Ecto.UUID.generate()}

      part =
        struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: "演示🎧.#{@format}")

      expected = %{
        "type" => "audio",
        "descriptor" => descriptor,
        "delivery" => delivery,
        "name" => "演示🎧.#{@format}"
      }

      assert {:ok, ^part} = Part.cast(expected)
      assert {:ok, ^expected} = Part.dump(part)
      assert {:ok, ^part} = expected |> Jason.encode!() |> Jason.decode!() |> Part.load()

      changeset =
        Message.changeset(%Message{}, %{role: "assistant", session_id: id, parts: [expected]})

      assert changeset.valid?
      assert %Message{parts: [^part]} = apply_changes(changeset)

      message = %Message{
        id: Ecto.UUID.generate(),
        session_id: id,
        role: "assistant",
        token_count: 0,
        inserted_at: DateTime.utc_now(),
        parts: [part]
      }

      encoded = Message.encode(message)

      assert encoded.parts == [
               %{
                 type: "audio",
                 descriptor: descriptor,
                 delivery: delivery,
                 name: "演示🎧.#{@format}"
               }
             ]

      assert :ok = Store.commit_turn(id, 0, encoded, %{turn_count: 1})
      assert {:ok, ^encoded} = Store.get_turn(id, 0)
      assert [^message] = Message.list_by_session(id)
      assert [^message] = Message.list_recent_by_session(id, 1)

      assert Part.Audio.summary(part) ==
               "Delivered audio: 演示🎧.#{@format}\nURI: #{descriptor["uri"]}\nMIME: #{@mime}\nDelivery: v1 #{id}/#{delivery["id"]}"
    end
  end
end
