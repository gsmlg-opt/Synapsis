defmodule Synapsis.AudioPartFunctionalTest do
  use Synapsis.DataCase
  @moduletag :functional

  alias Synapsis.{Message, Part}
  alias Synapsis.Part.Audio
  alias Synapsis.Session.Store

  test "audio part casts and round trips its exact public values through JSON" do
    part = audio()

    stored = %{
      "type" => "audio",
      "descriptor" => part.descriptor,
      "delivery" => part.delivery,
      "name" => part.name
    }

    assert {:ok, ^part} = Part.cast(stored)
    assert {:ok, ^part} = Part.cast(part)

    assert {:ok, ^part} =
             Part.cast(%{
               type: "audio",
               descriptor: part.descriptor,
               delivery: part.delivery,
               name: part.name
             })

    assert {:ok, ^stored} = Part.dump(part)
    assert {:ok, ^part} = stored |> Jason.encode!() |> Jason.decode!() |> Part.load()
  end

  test "assistant message changeset casts a public audio part" do
    part = audio()

    changeset =
      Message.changeset(%Message{}, %{
        role: "assistant",
        session_id: part.delivery["session_id"],
        parts: [
          %{
            "type" => "audio",
            "descriptor" => part.descriptor,
            "delivery" => part.delivery,
            "name" => part.name
          }
        ]
      })

    assert changeset.valid?
    assert %Message{role: "assistant", parts: [^part]} = apply_changes(changeset)
  end

  test "audio assistant turn retains its exact descriptor and delivery in Concord" do
    part = audio()
    session_id = part.delivery["session_id"]
    on_exit(fn -> Store.delete_session(session_id) end)

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      role: "assistant",
      inserted_at: DateTime.utc_now(),
      token_count: 0,
      parts: [part]
    }

    encoded = Message.encode(message)

    assert encoded.parts == [
             %{
               type: "audio",
               descriptor: part.descriptor,
               delivery: part.delivery,
               name: part.name
             }
           ]

    assert :ok = Store.commit_turn(session_id, 0, encoded, %{turn_count: 1})
    assert {:ok, ^encoded} = Store.get_turn(session_id, 0)
    assert [^message] = Message.list_by_session(session_id)
    assert [^message] = Message.list_recent_by_session(session_id, 1)
  end

  test "audio history summary identifies the delivered artifact using public values" do
    part = audio()
    reference = part.delivery

    assert Audio.summary(part) ==
             "Delivered audio: #{part.name}\n" <>
               "URI: #{part.descriptor["uri"]}\n" <>
               "MIME: #{part.descriptor["mime_type"]}\n" <>
               "Delivery: v1 #{reference["session_id"]}/#{reference["id"]}"
  end

  test "long Unicode audio names and MIME parameters have a bounded valid summary" do
    part = audio()

    descriptor =
      Map.put(
        part.descriptor,
        "mime_type",
        "audio/mpeg; title=\"#{String.duplicate("景", 3_000)}\""
      )

    for name <- [String.duplicate("演示🎧", 3_000), "界" <> String.duplicate("́", 3_000)] do
      summary = Audio.summary(%{part | name: name, descriptor: descriptor})

      assert is_binary(summary)
      assert String.valid?(summary)
      assert byte_size(summary) <= 2_048
      assert summary =~ "Delivered audio: "
      assert summary =~ "URI: #{part.descriptor["uri"]}"
      assert summary =~ "MIME: audio/mpeg; title="
      assert summary =~ "Delivery: v1 #{part.delivery["session_id"]}/#{part.delivery["id"]}"
    end
  end

  test "nil audio name and message metadata retain exact values and part order" do
    part = %{audio() | name: nil}
    id = part.delivery["session_id"]
    on_exit(fn -> Store.delete_session(id) end)
    parts = [%Part.Text{content: "before"}, part, %Part.Text{content: "after"}]

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: id,
      role: "assistant",
      token_count: 17,
      inserted_at: DateTime.utc_now(),
      parts: parts,
      input_provenance: %{"source" => "fixture"},
      internal_turn_source: "fixture",
      reply_presentation: %{"route" => "ordinary"}
    }

    assert {:ok, dumped} = Part.dump(part)
    assert dumped["name"] == nil
    assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Part.load()
    encoded = Message.encode(message)

    assert Enum.at(encoded.parts, 1) == %{
             type: "audio",
             descriptor: part.descriptor,
             delivery: part.delivery,
             name: nil
           }

    json = encoded |> Jason.encode!() |> Jason.decode!()

    assert json["parts"] == [
             %{"type" => "text", "text" => "before"},
             dumped,
             %{"type" => "text", "text" => "after"}
           ]

    assert json["input_provenance"] == message.input_provenance
    assert json["internal_turn_source"] == message.internal_turn_source
    assert json["reply_presentation"] == message.reply_presentation

    assert :ok = Store.commit_turn(id, 0, encoded, %{status: "idle"})
    assert [^message] = Message.list_by_session(id)
    assert Audio.summary(part) =~ "Delivered audio: audio\n"
  end

  defp audio do
    sha256 = String.duplicate("a", 64)

    struct(Audio,
      descriptor: %{
        "uri" => "synapsis-media://audio/#{sha256}.mp3",
        "sha256" => sha256,
        "byte_size" => 96,
        "format" => "mp3",
        "mime_type" => "audio/mpeg"
      },
      delivery: %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      },
      name: "演示🎧.mp3"
    )
  end
end
