defmodule SynapsisWeb.DiffsResultViewFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Part.ToolResult
  alias SynapsisWeb.ToolResultView

  test "source viewer and independent PNG/PDF receipts retain checked links across JSON history" do
    session_id = Ecto.UUID.generate()
    delivery_id = Ecto.UUID.generate()
    viewer_path = "/plugins/diffs/view/0123456789abcdef0123/" <> String.duplicate("a", 48)
    viewer_url = "https://diffs.example.test/base" <> viewer_path
    viewer_expiry = "2026-11-08T04:30:00.000Z"
    file_expiry = "2026-11-08T04:30:01.000Z"
    file_url = "/api/diffs/files/#{session_id}/#{delivery_id}"

    for {mode, format} <- [{"view", "png"}, {"file", "pdf"}, {"image", "png"}, {"both", "png"}] do
      details = %{
        "changed" => true,
        "artifactId" => "0123456789abcdef0123",
        "title" => "Value update",
        "inputKind" => "before_after",
        "fileCount" => 1,
        "mode" => mode,
        "expiresAt" => viewer_expiry
      }

      viewer = %{
        type: "link",
        kind: "diffs-viewer",
        label: "Open diff viewer",
        href: viewer_url,
        expiresAt: viewer_expiry
      }

      file = %{
        type: "link",
        kind: "diffs-file",
        label: "Download " <> String.upcase(format),
        href: file_url,
        filename: "preview." <> format,
        mediaType: if(format == "pdf", do: "application/pdf", else: "image/png"),
        bytes: 12345,
        expiresAt: file_expiry
      }

      details =
        if mode in ~w(view both),
          do: Map.merge(details, %{"viewerUrl" => viewer_url, "viewerPath" => viewer_path}),
          else: details

      details =
        if mode in ~w(file image both) do
          Map.merge(details, %{
            "filePath" => "/artifact-root/preview.#{format}",
            "path" => "/artifact-root/preview.#{format}",
            "fileBytes" => 12345,
            "fileFormat" => format,
            "fileExpiresAt" => file_expiry,
            "fileDelivery" => %{"version" => 1, "session_id" => session_id, "id" => delivery_id}
          })
        else
          details
        end

      text = "Source text receipt remains literal"

      part = %ToolResult{
        tool_use_id: "ordinary-diffs-display",
        content: text,
        projection: %{
          "version" => 1,
          "result" => %{
            "content" => [%{"type" => "text", "text" => text}],
            "details" => details,
            "is_error" => false
          }
        }
      }

      expected =
        [%{type: "text", text: text}] ++
          if(mode in ~w(view both), do: [viewer], else: []) ++
          if(mode in ~w(file image both), do: [file], else: [])

      display = ToolResultView.present(part)
      assert display.blocks == expected
      assert display.isError == false
      assert Enum.find(display.sidecars, &(&1.key == "details")).value == details

      assert ToolResultView.present(%{
               part
               | projection: Jason.decode!(Jason.encode!(part.projection))
             }) == display
    end
  end
end
