defmodule Synapsis.Provider.PCMAudioHistoryFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.{Message, Part}
  alias Synapsis.Provider.MessageMapper

  for protocol <- [:anthropic, :openai, :openai_responses, :google] do
    @protocol protocol
    test "#{protocol} projects opaque PCM as the canonical ordinary text summary" do
      sha = String.duplicate("d", 64)

      descriptor = %{
        "uri" => "synapsis-media://audio/#{sha}.pcm",
        "sha256" => sha,
        "byte_size" => 48,
        "format" => "pcm",
        "mime_type" => "application/octet-stream"
      }

      delivery = %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      }

      audio = struct(Part.Audio, descriptor: descriptor, delivery: delivery, name: "Ordinary.pcm")

      summary =
        "Delivered audio: Ordinary.pcm\nURI: #{descriptor["uri"]}\nMIME: application/octet-stream\nDelivery: v1 #{delivery["session_id"]}/#{delivery["id"]}"

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
