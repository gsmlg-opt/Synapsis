defmodule SynapsisWeb.AgentLive.VideoPartFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.{Message, Part}
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media
  alias SynapsisWeb.AgentLive.SessionChat

  @moduletag :tmp_dir
  @clip Path.expand("../../../fixtures/video/sample.mp4", __DIR__)

  test "shared chat projects a published real MP4 identically before and after durable reload", %{
    tmp_dir: root
  } do
    bytes = File.read!(@clip)
    id = Ecto.UUID.generate()
    assert {:ok, descriptor} = Media.put_video(bytes, "video/mp4", root: root)

    invocation = %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "video-display-fixture",
      tool_name: "video-display-fixture"
    }

    assert {:ok, delivery} =
             MediaDelivery.publish_video(descriptor, id, invocation,
               root: root,
               max_bytes: byte_size(bytes)
             )

    on_exit(fn -> Store.delete_session(id) end)
    video = struct(Part.Video, descriptor: descriptor, delivery: delivery, name: "Clip 🙂.mp4")

    message = %Message{
      id: Ecto.UUID.generate(),
      role: "assistant",
      session_id: id,
      parts: [video]
    }

    before_reload = snapshot(id, message)
    assert :ok = Store.commit_turn(id, 0, Message.encode(message), %{status: "idle"})
    assert [loaded] = Message.list_by_session(id)
    assert snapshot(id, loaded) == before_reload
    assert [projected] = hd(before_reload.messages).metadata.parts
    assert {:ok, url} = MediaDelivery.video_url(delivery)
    assert projected == %{type: "video", src: url, mediaType: "video/mp4", filename: "Clip 🙂.mp4"}

    assert {:ok, %{video: ^bytes, descriptor: ^descriptor}} =
             MediaDelivery.read_video(id, delivery["id"])
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
