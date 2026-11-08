defmodule SynapsisWeb.AgentLive.DeliveredImagePartFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.{Message, Part}
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media
  alias SynapsisWeb.AgentLive.SessionChat

  @moduletag :tmp_dir
  @image Path.expand("../../../fixtures/image/delivered.png", __DIR__)

  test "shared chat retains a published real PNG URL and name across durable reload", %{
    tmp_dir: root
  } do
    for name <- ["Result 🙂.png", nil] do
      {id, image, bytes} = delivered_image(root, name)

      message = %Message{
        id: Ecto.UUID.generate(),
        role: "assistant",
        session_id: id,
        parts: [image]
      }

      initial = snapshot(id, message)
      assert :ok = Store.commit_turn(id, 0, Message.encode(message), %{status: "idle"})
      assert [loaded] = Message.list_by_session(id)
      assert snapshot(id, loaded) == initial
      assert [projected] = hd(initial.messages).metadata.parts
      assert {:ok, url} = MediaDelivery.image_url(image.delivery)
      assert projected == %{type: "delivered_image", src: url, filename: name || "image"}

      assert {:ok, %{image: ^bytes, descriptor: descriptor}} =
               MediaDelivery.read_image(id, image.delivery["id"])

      assert descriptor == image.descriptor
    end
  end

  test "display name is bounded valid UTF-8 without changing durable image identity", %{
    tmp_dir: root
  } do
    name = String.duplicate("图片🎨", 200)
    {id, image, _bytes} = delivered_image(root, name)

    message = %Message{
      id: Ecto.UUID.generate(),
      role: "assistant",
      session_id: id,
      parts: [image]
    }

    assert [projected] = hd(snapshot(id, message).messages).metadata.parts
    assert projected.type == "delivered_image"
    assert String.valid?(projected.filename)
    assert byte_size(projected.filename) <= 320
    assert String.starts_with?(name, String.trim_trailing(projected.filename, "..."))
    assert :ok = Store.commit_turn(id, 0, Message.encode(message), %{status: "idle"})
    assert [%Message{parts: [^image]}] = Message.list_by_session(id)
  end

  test "historical inline image projection retains its exact original fields" do
    id = Ecto.UUID.generate()
    inline = %Part.Image{media_type: "image/png", data: "aW5saW5l", path: "input.png"}
    message = %Message{id: Ecto.UUID.generate(), role: "user", session_id: id, parts: [inline]}
    assert [projected] = hd(snapshot(id, message).messages).metadata.parts

    assert projected == %{
             type: "image",
             media_type: "image/png",
             data: "aW5saW5l",
             path: "input.png"
           }
  end

  defp delivered_image(root, name) do
    bytes = File.read!(@image)
    id = Ecto.UUID.generate()
    assert {:ok, descriptor} = Media.put_image(bytes, "png", root: root)

    invocation = %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "image-display-fixture",
      tool_name: "image-display-fixture"
    }

    assert {:ok, delivery} =
             MediaDelivery.publish_image(descriptor, id, invocation,
               root: root,
               max_bytes: byte_size(bytes)
             )

    on_exit(fn -> Store.delete_session(id) end)

    {id, struct(Part.DeliveredImage, descriptor: descriptor, delivery: delivery, name: name),
     bytes}
  end

  defp snapshot(id, message) do
    SessionChat.snapshot(%{
      messages: [message],
      session_status: "idle",
      current_session: %{id: id, config: %{}},
      agent_config: %{label: "Fixture", icon: nil},
      agent_id: "fixture",
      streaming_text: "",
      streaming_reasoning: "",
      tool_calls: %{},
      permission_requests: [],
      queued_inputs: [],
      heartbeat_notifications: [],
      code_agent_sessions: %{}
    })
  end
end
