defmodule Synapsis.DeliveredImagePartFunctionalTest do
  use Synapsis.DataCase
  @moduletag :functional

  alias Synapsis.{Message, Part}
  alias Synapsis.Part.{DeliveredImage, Image, Video}
  alias Synapsis.Session.Store

  test "delivered image casts and round trips its exact public values through JSON" do
    part = delivered_image()
    stored = public_part(part, "delivered_image")

    assert Map.keys(Map.from_struct(part)) |> Enum.sort() == [:delivery, :descriptor, :name]
    assert {:ok, ^part} = Part.cast(stored)
    assert {:ok, ^part} = Part.cast(part)

    assert {:ok, ^part} =
             Part.cast(%{
               type: "delivered_image",
               descriptor: part.descriptor,
               delivery: part.delivery,
               name: part.name
             })

    assert {:ok, ^stored} = Part.dump(part)
    assert {:ok, ^part} = stored |> Jason.encode!() |> Jason.decode!() |> Part.load()
  end

  test "delivered image without a display name retains its public identity" do
    part = %{delivered_image() | name: nil}
    stored = public_part(part, "delivered_image")

    assert {:ok, ^part} = Part.cast(Map.delete(stored, "name"))
    assert {:ok, ^stored} = Part.dump(part)
    assert {:ok, ^part} = stored |> Jason.encode!() |> Jason.decode!() |> Part.load()
    assert DeliveredImage.summary(part) =~ "Delivered image: image\n"
  end

  test "assistant message changeset casts a public delivered image part" do
    part = delivered_image()

    changeset =
      Message.changeset(%Message{}, %{
        role: "assistant",
        session_id: part.delivery["session_id"],
        parts: [public_part(part, "delivered_image")]
      })

    assert changeset.valid?
    assert %Message{role: "assistant", parts: [^part]} = apply_changes(changeset)
  end

  test "delivered image assistant turn retains its exact descriptor and delivery in Concord" do
    for name <- ["演示🎨.png", nil] do
      part = %{delivered_image() | name: name}
      message = message(part.delivery["session_id"], [part])
      encoded = Message.encode(message)

      assert encoded.parts == [
               %{
                 type: "delivered_image",
                 descriptor: part.descriptor,
                 delivery: part.delivery,
                 name: name
               }
             ]

      assert_roundtrip(message, encoded)
    end
  end

  test "delivered image summary identifies the artifact using its exact public values" do
    part = delivered_image()
    reference = part.delivery

    assert DeliveredImage.summary(part) ==
             "Delivered image: #{part.name}\n" <>
               "URI: #{part.descriptor["uri"]}\n" <>
               "MIME: #{part.descriptor["mime_type"]}\n" <>
               "Delivery: v1 #{reference["session_id"]}/#{reference["id"]}"
  end

  test "long Unicode public summary fields produce bounded valid UTF-8" do
    part = delivered_image()

    for text <- [String.duplicate("演示🎨", 3_000), "界" <> String.duplicate("́", 3_000)] do
      summary =
        DeliveredImage.summary(%{
          part
          | name: text,
            descriptor: %{"uri" => text, "mime_type" => text},
            delivery: %{
              "version" => String.to_integer(String.duplicate("9", 1_000)),
              "session_id" => text,
              "id" => text
            }
        })

      assert is_binary(summary)
      assert String.valid?(summary)
      assert byte_size(summary) <= 2_048
      assert summary =~ "Delivered image: "
      assert summary =~ "\nURI: "
      assert summary =~ "\nMIME: "
      assert summary =~ "\nDelivery: v"
    end
  end

  test "inline image and delivered video retain their exact historical wire values" do
    image = %Image{media_type: "image/png", data: "aW1hZ2U=", path: "images/example.png"}

    image_stored = %{
      "type" => "image",
      "media_type" => image.media_type,
      "data" => image.data,
      "path" => image.path
    }

    video =
      struct(Video,
        descriptor: %{
          "uri" => "synapsis-media://video/#{String.duplicate("b", 64)}.mp4",
          "sha256" => String.duplicate("b", 64),
          "byte_size" => 128,
          "format" => "mp4",
          "mime_type" => "video/mp4"
        },
        delivery: %{
          "version" => 1,
          "session_id" => Ecto.UUID.generate(),
          "id" => Ecto.UUID.generate()
        },
        name: "演示🎥.mp4"
      )

    video_stored = public_part(video, "video")

    for {part, stored} <- [{image, image_stored}, {video, video_stored}] do
      assert {:ok, ^part} = Part.cast(stored)
      assert {:ok, ^stored} = Part.dump(part)
      assert {:ok, ^part} = stored |> Jason.encode!() |> Jason.decode!() |> Part.load()
    end

    message = message(video.delivery["session_id"], [image, video])
    encoded = Message.encode(message)

    assert encoded.parts == [
             %{type: "image", media_type: image.media_type, data: image.data, path: image.path},
             %{
               type: "video",
               descriptor: video.descriptor,
               delivery: video.delivery,
               name: video.name
             }
           ]

    assert_roundtrip(message, encoded)
  end

  defp assert_roundtrip(message, encoded) do
    session_id = message.session_id
    on_exit(fn -> Store.delete_session(session_id) end)

    assert :ok = Store.commit_turn(session_id, 0, encoded, %{turn_count: 1})
    assert {:ok, ^encoded} = Store.get_turn(session_id, 0)
    assert [^message] = Message.list_by_session(session_id)
    assert [^message] = Message.list_recent_by_session(session_id, 1)
  end

  defp message(session_id, parts) do
    %Message{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      role: "assistant",
      inserted_at: DateTime.utc_now(),
      token_count: 0,
      parts: parts
    }
  end

  defp public_part(part, type) do
    %{
      "type" => type,
      "descriptor" => part.descriptor,
      "delivery" => part.delivery,
      "name" => part.name
    }
  end

  defp delivered_image do
    sha256 = String.duplicate("a", 64)

    struct(DeliveredImage,
      descriptor: %{
        "uri" => "synapsis-media://image/#{sha256}.png",
        "sha256" => sha256,
        "byte_size" => 96,
        "format" => "png",
        "mime_type" => "image/png"
      },
      delivery: %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      },
      name: "演示🎨.png"
    )
  end
end
