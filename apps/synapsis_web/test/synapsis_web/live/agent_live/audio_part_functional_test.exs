defmodule SynapsisWeb.AgentLive.AudioPartFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.{Message, Part}
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media
  alias SynapsisWeb.AgentLive.SessionChat

  @moduletag :tmp_dir
  @fixtures Path.expand("../../../../../synapsis_provider/test/fixtures/speech", __DIR__)
  @pcm (for sample <- 0..7999, into: <<>> do
          value = round(:math.sin(2 * :math.pi() * 440 * sample / 8000) * 12000)
          <<value::signed-little-16>>
        end)
  @wav <<"RIFF", 36 + byte_size(@pcm)::little-32, "WAVEfmt ", 16::little-32, 1::little-16,
         1::little-16, 8000::little-32, 16000::little-32, 2::little-16, 16::little-16, "data",
         byte_size(@pcm)::little-32, @pcm::binary>>

  for {format, bytes} <- [
        {"mp3", File.read!(Path.join(@fixtures, "tone.mp3"))},
        {"opus", File.read!(Path.join(@fixtures, "tone.opus"))},
        {"wav", @wav}
      ] do
    @format format
    @audio bytes
    test "shared chat retains exact published #{@format} projection and original bytes after reload",
         %{tmp_dir: root} do
      id = Ecto.UUID.generate()
      assert {:ok, descriptor} = Media.put_audio(@audio, @format, root: root)

      invocation = %{
        run_id: Ecto.UUID.generate(),
        invocation_id: Ecto.UUID.generate(),
        tool_call_id: "audio-display-fixture",
        tool_name: "audio-display-fixture"
      }

      assert {:ok, delivery} =
               MediaDelivery.publish(descriptor, id, invocation,
                 root: root,
                 max_bytes: byte_size(@audio)
               )

      on_exit(fn -> Store.delete_session(id) end)
      assert {:ok, url} = MediaDelivery.url(delivery)

      assert {:ok, tool_part} =
               Synapsis.Agent.Tools.ResultProjection.to_part("ordinary-audio", %{
                 content: [%{type: "text", text: "spoken"}],
                 details: %{mediaDescriptor: descriptor, mediaDelivery: delivery}
               })

      assert SynapsisWeb.ToolResultView.present(tool_part).blocks == [
               %{type: "text", text: "spoken"},
               %{
                 type: "audio",
                 src: url,
                 mediaType: descriptor["mime_type"],
                 filename: "audio.#{@format}"
               }
             ]

      for name <- ["Audio 🎧.#{@format}", nil] do
        audio = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: name)

        message = %Message{
          id: Ecto.UUID.generate(),
          role: "assistant",
          session_id: id,
          parts: [%Part.Text{content: "before"}, audio, %Part.Text{content: "after"}]
        }

        before_reload = snapshot(id, message)
        assert :ok = Store.commit_turn(id, 0, Message.encode(message), %{status: "idle"})
        assert [loaded] = Message.list_by_session(id)
        assert loaded == message
        assert snapshot(id, loaded) == before_reload

        assert hd(before_reload.messages).metadata.parts == [
                 %{type: "text", content: "before"},
                 %{
                   type: "audio",
                   src: url,
                   mediaType: descriptor["mime_type"],
                   filename: name || "audio.#{@format}"
                 },
                 %{type: "text", content: "after"}
               ]

        assert {:ok, %{audio: @audio, descriptor: ^descriptor}} =
                 MediaDelivery.read(id, delivery["id"])
      end

      if destination = System.get_env("SYNAPSIS_TOOL_RESULT_UI_EVIDENCE") do
        audio = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: nil)

        message = %Message{
          id: Ecto.UUID.generate(),
          role: "assistant",
          session_id: id,
          parts: [audio]
        }

        before_reload = snapshot(id, message)
        assert :ok = Store.commit_turn(id, 0, Message.encode(message), %{status: "idle"})
        [loaded] = Message.list_by_session(id)

        File.write!(
          Path.join(destination, "audio-part-#{@format}.json"),
          Jason.encode!(%{
            before: before_reload,
            history: snapshot(id, loaded),
            audio: Base.encode64(@audio),
            descriptor: descriptor,
            delivery: delivery
          })
        )

        File.write!(Path.join(destination, "audio-part.#{@format}"), @audio)
      end
    end
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
