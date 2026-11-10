defmodule Synapsis.VideoPartFunctionalTest do
  use Synapsis.DataCase
  @moduletag :functional

  alias Synapsis.{Message, Part}
  alias Synapsis.Part.Video
  alias Synapsis.Session.Store

  test "video part casts and round trips its exact public values through JSON" do
    part = video()

    stored = %{
      "type" => "video",
      "descriptor" => part.descriptor,
      "delivery" => part.delivery,
      "name" => part.name
    }

    assert {:ok, ^part} = Part.cast(stored)
    assert {:ok, ^part} = Part.cast(part)

    assert {:ok, ^part} =
             Part.cast(%{
               type: "video",
               descriptor: part.descriptor,
               delivery: part.delivery,
               name: part.name
             })

    assert {:ok, ^stored} = Part.dump(part)
    assert {:ok, ^part} = stored |> Jason.encode!() |> Jason.decode!() |> Part.load()
  end

  test "assistant message changeset casts a public video part" do
    part = video()

    changeset =
      Message.changeset(%Message{}, %{
        role: "assistant",
        session_id: part.delivery["session_id"],
        parts: [
          %{
            "type" => "video",
            "descriptor" => part.descriptor,
            "delivery" => part.delivery,
            "name" => part.name
          }
        ]
      })

    assert changeset.valid?
    assert %Message{role: "assistant", parts: [^part]} = apply_changes(changeset)
  end

  test "video assistant turn retains its exact descriptor and delivery in Concord" do
    part = video()
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
               type: "video",
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

  test "video history summary identifies the delivered artifact using public values" do
    part = video()
    reference = part.delivery

    assert Video.summary(part) ==
             "Delivered video: #{part.name}\n" <>
               "URI: #{part.descriptor["uri"]}\n" <>
               "MIME: #{part.descriptor["mime_type"]}\n" <>
               "Delivery: v1 #{reference["session_id"]}/#{reference["id"]}"
  end

  test "long Unicode video names and MIME parameters have a bounded valid summary" do
    part = video()

    descriptor =
      Map.put(
        part.descriptor,
        "mime_type",
        "video/mp4; title=\"#{String.duplicate("景", 3_000)}\""
      )

    for name <- [String.duplicate("演示🎥", 3_000), "界" <> String.duplicate("́", 3_000)] do
      summary = Video.summary(%{part | name: name, descriptor: descriptor})

      assert is_binary(summary)
      assert String.valid?(summary)
      assert byte_size(summary) <= 2_048
      assert summary =~ "Delivered video: "
      assert summary =~ "URI: #{part.descriptor["uri"]}"
      assert summary =~ "MIME: video/mp4; title="
      assert summary =~ "Delivery: v1 #{part.delivery["session_id"]}/#{part.delivery["id"]}"
    end
  end

  defp video do
    sha256 = String.duplicate("a", 64)

    struct(Video,
      descriptor: %{
        "uri" => "synapsis-media://video/#{sha256}.mp4",
        "sha256" => sha256,
        "byte_size" => 96,
        "format" => "mp4",
        "mime_type" => "video/mp4; codecs=\"avc1.42E01E\""
      },
      delivery: %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      },
      name: "演示🎥.mp4"
    )
  end
end
