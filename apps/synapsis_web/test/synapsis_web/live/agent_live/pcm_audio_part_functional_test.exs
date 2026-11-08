defmodule SynapsisWeb.AgentLive.PCMAudioPartFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.{Message, Part}
  alias Synapsis.Session.Store
  alias Synapsis.Workspace.Media
  alias SynapsisWeb.AgentLive.SessionChat
  alias SynapsisWeb.ToolResultView

  @moduletag :tmp_dir
  @audio <<0, 255, 128, "ordinary opaque PCM chat", 0, 254, 19>>

  test "tool-result and Audio parts share the exact opaque PCM download projection before and after reload",
       %{tmp_dir: root} do
    id = Ecto.UUID.generate()
    media_root = Path.join(root, "original-pcm")
    on_exit(fn -> Store.delete_session(id) end)
    assert {:ok, descriptor} = Media.put_audio(@audio, "pcm", root: media_root)
    sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

    assert descriptor == %{
             "uri" => "synapsis-media://audio/#{sha}.pcm",
             "sha256" => sha,
             "byte_size" => byte_size(@audio),
             "format" => "pcm",
             "mime_type" => "application/octet-stream"
           }

    operation = %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-pcm-chat",
      tool_name: "synapsis::tts"
    }

    assert {:ok, delivery} =
             MediaDelivery.publish(descriptor, id, operation, root: media_root, max_bytes: 4_096)

    assert {:ok, url} = MediaDelivery.url(delivery)

    block = %{
      type: "audio",
      src: url,
      mediaType: "application/octet-stream",
      filename: "audio.pcm"
    }

    assert {:ok, tool_result} =
             ResultProjection.to_part("ordinary-pcm-chat", %{
               content: [%{type: "text", text: "(spoken) Ordinary PCM fixture."}],
               details: %{
                 provider: "openrouter",
                 audioPath: descriptor["uri"],
                 media: %{mediaUrl: descriptor["uri"], trustedLocalMedia: true},
                 mediaDescriptor: descriptor,
                 mediaDelivery: delivery
               }
             })

    display = ToolResultView.present(tool_result)
    assert display.blocks == [%{type: "text", text: "(spoken) Ordinary PCM fixture."}, block]

    tool_message = %Message{
      id: Ecto.UUID.generate(),
      role: "assistant",
      session_id: id,
      parts: [
        %Part.ToolUse{
          tool: "synapsis::tts",
          tool_use_id: "ordinary-pcm-chat",
          input: %{"text" => "Ordinary PCM fixture."}
        },
        tool_result
      ]
    }

    tool_before = snapshot(id, tool_message)
    assert [_, projected] = hd(tool_before.messages).metadata.parts
    assert projected.type == "tool_result"
    assert projected.display == display
    assert :ok = Store.commit_turn(id, 0, Message.encode(tool_message), %{status: "idle"})
    assert [loaded_tool] = Message.list_by_session(id)
    assert loaded_tool == tool_message
    tool_history = snapshot(id, loaded_tool)
    assert tool_history == tool_before

    part_snapshots =
      for name <- ["Audio 🎧.pcm", nil] do
        audio = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: name)

        message = %Message{
          id: Ecto.UUID.generate(),
          role: "assistant",
          session_id: id,
          parts: [
            %Part.Text{content: "before"},
            audio,
            %Part.Text{content: "after"}
          ]
        }

        before = snapshot(id, message)

        assert hd(before.messages).metadata.parts == [
                 %{type: "text", content: "before"},
                 Map.put(block, :filename, name || "audio.pcm"),
                 %{type: "text", content: "after"}
               ]

        assert :ok = Store.commit_turn(id, 1, Message.encode(message), %{status: "idle"})
        assert [^tool_message, loaded] = Message.list_by_session(id)
        assert loaded == message
        history = snapshot(id, loaded)
        assert history == before

        assert {:ok, %{audio: @audio, descriptor: ^descriptor}} =
                 MediaDelivery.read(id, delivery["id"])

        %{before: before, history: history}
      end

    assert [file] = Path.wildcard(Path.join(media_root, "**/*.pcm"))
    assert File.read!(file) == @audio

    if destination = System.get_env("SYNAPSIS_TOOL_RESULT_UI_EVIDENCE") do
      File.write!(
        Path.join(destination, "pcm-audio-projections.json"),
        Jason.encode!(%{
          tool: %{before: tool_before, history: tool_history},
          part: List.last(part_snapshots),
          part_variants: part_snapshots,
          descriptor: descriptor,
          delivery: delivery,
          url: url,
          original_root: media_root,
          audio: Base.encode64(@audio),
          metadata: %{
            format: "pcm",
            mime_type: "application/octet-stream",
            filename: "audio.pcm",
            sha256: sha,
            byte_size: byte_size(@audio)
          }
        })
      )

      File.write!(Path.join(destination, "pcm-audio.pcm"), @audio)
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
