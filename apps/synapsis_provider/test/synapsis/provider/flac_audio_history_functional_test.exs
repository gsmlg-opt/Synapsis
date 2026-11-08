defmodule Synapsis.Provider.FLACAudioHistoryFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.{Message, Part}
  alias Synapsis.Provider.MessageMapper

  for {format, mime} <- [
        {"mp3", "audio/mpeg"},
        {"opus", "audio/ogg"},
        {"flac", "audio/flac"},
        {"wav", "audio/wav"},
        {"pcm", "application/octet-stream"}
      ],
      protocol <- [:anthropic, :openai, :openai_responses, :google] do
    @format format
    @mime mime
    @protocol protocol
    test "#{protocol} projects opaque #{format} as the canonical ordinary text summary" do
      sha = String.duplicate("d", 64)

      descriptor = %{
        "uri" => "synapsis-media://audio/#{sha}.#{@format}",
        "sha256" => sha,
        "byte_size" => 48,
        "format" => @format,
        "mime_type" => @mime
      }

      delivery = %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      }

      audio =
        struct(Part.Audio,
          descriptor: descriptor,
          delivery: delivery,
          name: "Ordinary.#{@format}"
        )

      summary =
        "Delivered audio: Ordinary.#{@format}\nURI: #{descriptor["uri"]}\nMIME: #{@mime}\nDelivery: v1 #{delivery["session_id"]}/#{delivery["id"]}"

      assert Part.Audio.summary(audio) == summary

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

      assert {:ok, expected} =
               MessageMapper.build_request(
                 @protocol,
                 [
                   %Message{
                     role: "assistant",
                     parts: [
                       %Part.Text{content: "before"},
                       %Part.Text{content: summary},
                       %Part.Text{content: "after"}
                     ]
                   }
                 ],
                 [],
                 %{model: "fixture"}
               )

      assert wire == expected

      assert Enum.filter(texts(wire), &(&1 in ["before", summary, "after"])) == [
               "before",
               summary,
               "after"
             ]
    end
  end

  defp texts(value) when is_binary(value), do: [value]
  defp texts(value) when is_list(value), do: Enum.flat_map(value, &texts/1)
  defp texts(value) when is_map(value), do: Enum.flat_map(value, fn {_, v} -> texts(v) end)
  defp texts(_), do: []
end
