defmodule SynapsisWeb.ToolResultViewFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.Part.ToolResult
  alias SynapsisWeb.ToolResultView

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

  test "legacy tool text remains literal and retains its status" do
    text = "**literal tool output**\n<fixture>"
    part = %ToolResult{tool_use_id: "legacy", content: text}

    assert ToolResultView.present(part) == %{
             blocks: [%{type: "text", text: text}],
             sidecars: [],
             error: nil,
             isError: false
           }
  end

  test "ordered native text image text preserves the exact inline image bytes" do
    content = [
      %{"type" => "text", "text" => "before"},
      %{"type" => "image", "mimeType" => "image/png", "data" => @png},
      %{"type" => "text", "text" => "after"}
    ]

    display = content |> projected() |> ToolResultView.present()

    assert display.blocks == [
             %{type: "text", text: "before"},
             %{
               type: "image",
               src: "data:image/png;base64," <> @png,
               mediaType: "image/png",
               alt: "Tool result image"
             },
             %{type: "text", text: "after"}
           ]

    assert display.isError == false
  end

  test "typed inline images and native base64 sources preserve their existing representation" do
    for mime <- ~w(image/png image/jpeg image/gif image/webp) do
      uri = "data:#{mime};base64,#{@png}"

      for block <- [
            %{"type" => "image", "data" => %{"mime_type" => mime, "data" => @png}},
            %{"type" => "image", "data" => %{"mime_type" => mime, "data" => uri}},
            %{
              "type" => "image",
              "data" => %{"source" => "base64", "media_type" => mime, "data" => @png}
            }
          ] do
        assert [%{type: "image", src: ^uri, mediaType: ^mime}] =
                 [block] |> projected() |> ToolResultView.present() |> Map.fetch!(:blocks)
      end
    end
  end

  test "native view_image public projection retains its image and metadata" do
    native = %{
      path: "fixture.png",
      detail: "original",
      mime_type: "image/png",
      bytes: byte_size(Base.decode64!(@png)),
      data: Base.decode64!(@png),
      image_url: "data:image/png;base64," <> @png,
      is_error: false
    }

    assert {:ok, part} = ResultProjection.to_part("image", native, tool_name: "view_image")
    display = ToolResultView.present(part)
    assert [%{type: "text"}, %{type: "image", src: src}] = display.blocks
    assert src == native.image_url
    assert [%{key: "metadata", label: "Metadata", value: metadata}] = display.sidecars
    assert metadata["path"] == "fixture.png"
    assert metadata["detail"] == "original"
    assert metadata["bytes"] == native.bytes
  end

  test "image references resources links and audio expose readable metadata" do
    content = [
      %{"type" => "image", "data" => %{"uri" => "fixture://image", "mime_type" => "image/png"}},
      %{
        "type" => "resource",
        "resource" => %{
          "uri" => "fixture://report",
          "mimeType" => "text/plain",
          "text" => "Report"
        }
      },
      %{
        "type" => "resource_link",
        "data" => %{"uri" => "fixture://report", "name" => "report.txt", "size" => 6}
      },
      %{"type" => "audio", "data" => %{"mime_type" => "audio/wav", "data" => "UklGRg=="}}
    ]

    display = content |> projected() |> ToolResultView.present()

    assert Enum.map(display.blocks, & &1.type) == List.duplicate("reference", 4)
    assert Enum.map(display.blocks, & &1.kind) == ~w(image resource resource_link audio)
    assert Enum.at(display.blocks, 0).value["data"]["uri"] == "fixture://image"
    assert Enum.at(display.blocks, 1).value["resource"]["text"] == "Report"
    assert Enum.at(display.blocks, 2).value["data"]["name"] == "report.txt"
    assert Enum.at(display.blocks, 3).value["data"]["mime_type"] == "audio/wav"

    assert Enum.at(display.blocks, 3).value["data"]["data"] == %{
             omitted: "inline media",
             encodedCharacters: 8
           }
  end

  test "content objects and native structured sidecars remain inspectable JSON values" do
    result = %{
      "content" => %{"matches" => [%{"path" => "report.txt", "line" => 4}]},
      "structured" => %{"count" => 1},
      "artifacts" => [%{"uri" => "fixture://report"}],
      "details" => %{"source" => "fixture"},
      "progress" => %{"completed" => 2, "total" => 3},
      "pagination" => %{"next_cursor" => "page-2", "has_more" => true},
      "status" => "running",
      "session_id" => "command-42",
      "truncated" => true,
      "is_error" => false
    }

    display = result |> projected_result() |> ToolResultView.present()
    assert display.blocks == [%{type: "json", label: "Content", value: result["content"]}]

    assert Enum.map(display.sidecars, & &1.key) ==
             ~w(structured artifacts details progress pagination metadata)

    for key <- ~w(structured artifacts details progress pagination) do
      assert Enum.find(display.sidecars, &(&1.key == key)).value == result[key]
    end

    assert List.last(display.sidecars).value == %{
             "status" => "running",
             "session_id" => "command-42",
             "truncated" => true
           }
  end

  defp projected(content), do: projected_result(%{"content" => content, "is_error" => false})

  defp projected_result(result) do
    %ToolResult{
      tool_use_id: "fixture",
      content: "legacy text view",
      projection: %{"version" => 1, "result" => result},
      is_error: false
    }
  end
end
