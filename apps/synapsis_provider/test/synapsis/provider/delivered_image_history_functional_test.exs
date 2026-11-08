defmodule Synapsis.Provider.DeliveredImageHistoryFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Part.DeliveredImage
  alias Synapsis.Provider.MessageMapper

  test "direct domain history delivers the same ordinary image summary to Anthropic" do
    image =
      struct(DeliveredImage,
        name: "Local image",
        descriptor: %{
          "uri" => "synapsis-media://image/" <> String.duplicate("b", 64) <> ".png",
          "sha256" => String.duplicate("b", 64),
          "byte_size" => 2048,
          "format" => "png",
          "mime_type" => "image/png"
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
               [%{role: "assistant", parts: [image]}],
               [],
               %{model: "fixture"}
             )

    assert wire["messages"] == [
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "text", "text" => DeliveredImage.summary(image)}
               ]
             }
           ]
  end
end
