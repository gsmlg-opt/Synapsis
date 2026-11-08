defmodule SynapsisServer.DeliveredImageHistoryFunctionalTest do
  use SynapsisServer.ChannelCase
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.{Message, Part, Session}
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @image Path.expand("../../../synapsis_web/test/fixtures/image/delivered.png", __DIR__)

  test "REST and channel retain delivered and historical inline images from actual Concord history",
       %{tmp_dir: root} do
    bytes = File.read!(@image)
    assert {:ok, descriptor} = Media.put_image(bytes, "png", root: root)

    for name <- ["Result 🙂.png", nil] do
      session = %Session{
        id: Ecto.UUID.generate(),
        provider: "image-history-fixture",
        model: "fixture"
      }

      assert :ok = Store.put_meta(session.id, Session.to_meta(session))
      on_exit(fn -> Synapsis.Sessions.delete(session.id) end)

      invocation = %{
        run_id: Ecto.UUID.generate(),
        invocation_id: Ecto.UUID.generate(),
        tool_call_id: "image-history-fixture",
        tool_name: "image-history-fixture"
      }

      assert {:ok, delivery} =
               MediaDelivery.publish_image(descriptor, session.id, invocation,
                 root: root,
                 max_bytes: byte_size(bytes)
               )

      image = struct(Part.DeliveredImage, descriptor: descriptor, delivery: delivery, name: name)

      inline = %Part.Image{
        media_type: "image/png",
        data: Base.encode64(bytes),
        path: "original.png"
      }

      message = %Message{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        role: "assistant",
        parts: [image, inline]
      }

      assert :ok =
               Store.commit_turn(session.id, 0, Message.encode(message), Session.to_meta(session))

      expected = [
        %{type: "delivered_image", descriptor: descriptor, delivery: delivery, name: name},
        %{type: "image", media_type: "image/png", data: Base.encode64(bytes)}
      ]

      response = build_conn() |> get("/api/sessions/#{session.id}") |> json_response(200)
      assert [%{"id" => id, "parts" => serialized}] = response["data"]["messages"]
      assert id == message.id
      assert serialized == expected |> Jason.encode!() |> Jason.decode!()
      assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})

      assert {:ok, %{messages: [%{parts: ^expected}]}, _} =
               join(socket, "session:#{session.id}", %{})

      assert {:ok, %{image: ^bytes, descriptor: ^descriptor}} =
               MediaDelivery.read_image(session.id, delivery["id"])
    end
  end
end
