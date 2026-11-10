defmodule SynapsisServer.AudioHistoryFunctionalTest do
  use SynapsisServer.ChannelCase
  @moduletag :functional
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]
  alias Synapsis.{Message, Part, Session}
  alias Synapsis.Session.Store

  test "REST and channel join retain the complete audio part from actual Concord history" do
    session = %Session{
      id: Ecto.UUID.generate(),
      provider: "audio-history-fixture",
      model: "fixture"
    }

    assert :ok = Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)

    descriptor = %{
      "uri" => "synapsis-media://audio/" <> String.duplicate("c", 64) <> ".mp3",
      "sha256" => String.duplicate("c", 64),
      "byte_size" => 256,
      "format" => "mp3",
      "mime_type" => "audio/mpeg"
    }

    delivery = %{"version" => 1, "session_id" => session.id, "id" => Ecto.UUID.generate()}
    audio = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: "Result 🙂")

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: session.id,
      role: "assistant",
      parts: [audio]
    }

    assert :ok =
             Store.commit_turn(session.id, 0, Message.encode(message), Session.to_meta(session))

    expected = %{type: "audio", descriptor: descriptor, delivery: delivery, name: "Result 🙂"}
    response = build_conn() |> get("/api/sessions/#{session.id}") |> json_response(200)
    assert [%{"id" => id, "parts" => [serialized]}] = response["data"]["messages"]
    assert id == message.id
    assert serialized == expected |> Jason.encode!() |> Jason.decode!()
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})

    assert {:ok, %{messages: [%{parts: [^expected]}]}, _} =
             join(socket, "session:#{session.id}", %{})
  end
end
