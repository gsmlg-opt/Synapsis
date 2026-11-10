defmodule Synapsis.Provider.VideoHistoryFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Part.Video
  alias Synapsis.Provider.MessageMapper

  test "direct domain history delivers the same ordinary video summary to Anthropic" do
    video =
      struct(Video,
        name: "Local clip",
        descriptor: %{
          "uri" => "synapsis-media://video/" <> String.duplicate("b", 64) <> ".mp4",
          "sha256" => String.duplicate("b", 64),
          "byte_size" => 2048,
          "format" => "mp4",
          "mime_type" => "video/mp4; codecs=avc1"
        },
        delivery: %{
          "version" => 1,
          "session_id" => Ecto.UUID.generate(),
          "id" => Ecto.UUID.generate()
        }
      )

    assert {:ok, wire} =
             MessageMapper.build_request(
               :anthropic,
               [%{role: "assistant", parts: [video]}],
               [],
               %{model: "fixture"}
             )

    assert wire["messages"] == [
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "text", "text" => Video.summary(video)}
               ]
             }
           ]
  end
end
