defmodule Synapsis.Provider.AudioHistoryFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.{Message, Part}
  alias Synapsis.Provider.MessageMapper

  for protocol <- [:anthropic, :openai, :openai_responses, :google] do
    @protocol protocol
    test "#{protocol} maps durable audio history to bounded text in order" do
      audio = audio()
      summary = Part.Audio.summary(audio)
      assert String.valid?(summary)
      assert byte_size(summary) <= 2048

      assert {:ok, wire} =
               MessageMapper.build_request(
                 @protocol,
                 [
                   %Message{
                     role: "assistant",
                     parts: [%Part.Text{content: "before"}, audio, %Part.Text{content: "after"}]
                   }
                 ],
                 [],
                 %{model: "fixture"}
               )

      reference = audio.delivery

      expected_summary =
        "Delivered audio: #{audio.name}\n" <>
          "URI: #{audio.descriptor["uri"]}\n" <>
          "MIME: #{audio.descriptor["mime_type"]}\n" <>
          "Delivery: v1 #{reference["session_id"]}/#{reference["id"]}"

      assert summary == expected_summary

      assert {:ok, text_wire} =
               MessageMapper.build_request(
                 @protocol,
                 [
                   %Message{
                     role: "assistant",
                     parts: [
                       %Part.Text{content: "before"},
                       %Part.Text{content: expected_summary},
                       %Part.Text{content: "after"}
                     ]
                   }
                 ],
                 [],
                 %{model: "fixture"}
               )

      assert wire == text_wire

      texts = texts(wire)

      assert Enum.filter(texts, &(&1 in ["before", summary, "after"])) == [
               "before",
               summary,
               "after"
             ]
    end

    test "#{protocol} keeps ordinary tools and existing delivered media summaries" do
      audio = audio()

      video =
        struct(Part.Video,
          descriptor: %{"uri" => "clip", "mime_type" => "video/mp4"},
          delivery: audio.delivery,
          name: "clip"
        )

      image =
        struct(Part.DeliveredImage,
          descriptor: %{"uri" => "picture", "mime_type" => "image/png"},
          delivery: audio.delivery,
          name: "picture"
        )

      call = %Part.ToolUse{tool_use_id: "ordinary", tool: "clock", input: %{}}
      result = %Part.ToolResult{tool_use_id: "ordinary", content: "12:00"}

      assert {:ok, wire} =
               MessageMapper.build_request(
                 @protocol,
                 [
                   %Message{role: "assistant", parts: [audio, video, image, call]},
                   %{role: "tool", parts: [result]}
                 ],
                 [],
                 %{model: "fixture"}
               )

      encoded = Jason.encode!(wire)
      assert encoded =~ "ordinary"
      assert encoded =~ "12:00"

      for summary <- [
            Part.Audio.summary(audio),
            Part.Video.summary(video),
            Part.DeliveredImage.summary(image)
          ] do
        assert summary in texts(wire)
      end
    end
  end

  test "inline image remains an image beside the text-only audio summary" do
    audio = audio()
    image = %Part.Image{media_type: "image/png", data: "AA=="}

    assert {:ok, wire} =
             MessageMapper.build_request(
               :anthropic,
               [%{role: "user", parts: [image]}, %{role: "assistant", parts: [audio]}],
               [],
               %{model: "fixture"}
             )

    assert [
             %{
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{"data" => "AA==", "media_type" => "image/png"}
                 }
               ]
             },
             %{"content" => [%{"type" => "text", "text" => summary}]}
           ] = wire["messages"]

    assert summary == Part.Audio.summary(audio)
  end

  defp texts(value) when is_binary(value), do: [value]
  defp texts(value) when is_list(value), do: Enum.flat_map(value, &texts/1)
  defp texts(value) when is_map(value), do: Enum.flat_map(value, fn {_, v} -> texts(v) end)
  defp texts(_), do: []

  defp audio do
    struct(Part.Audio,
      name: "Local audio 🎧",
      descriptor: %{
        "uri" => "synapsis-media://audio/" <> String.duplicate("b", 64) <> ".mp3",
        "sha256" => String.duplicate("b", 64),
        "byte_size" => 2048,
        "format" => "mp3",
        "mime_type" => "audio/mpeg"
      },
      delivery: %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      }
    )
  end
end
