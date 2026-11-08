defmodule Synapsis.Diffs.RendererFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Diffs.{PortSession, Request}

  @defaults %{
    "fontFamily" => "Fira Code",
    "fontSize" => 15,
    "lineSpacing" => 1.6,
    "layout" => "unified",
    "showLineNumbers" => true,
    "diffIndicators" => "bars",
    "wordWrap" => true,
    "background" => true,
    "theme" => "dark",
    "fileFormat" => "png",
    "fileQuality" => "standard",
    "fileScale" => 2,
    "fileMaxWidth" => 960,
    "mode" => "both",
    "ttlSeconds" => 1800
  }
  @image %{
    "format" => "png",
    "qualityPreset" => "standard",
    "scale" => 2,
    "maxWidth" => 960,
    "maxPixels" => 8_000_000
  }
  @arguments %{
    "before" => "const value = 1;\n",
    "after" => "const value = 2;\n",
    "path" => "src/value.ts",
    "lang" => "TS",
    "title" => " Value update ",
    "mode" => "both"
  }
  @patch Enum.join(
           [
             "diff --git a/a.ts b/a.ts",
             "--- a/a.ts",
             "+++ b/a.ts",
             "@@ -1,2 +1,3 @@",
             "-const a = 1;",
             "+const a = 2;",
             "+const extra = true;",
             " const keep = 0;",
             "diff --git a/b.ts b/b.ts",
             "--- a/b.ts",
             "+++ b/b.ts",
             "@@ -1 +1 @@",
             "-const b = 1;",
             "+const b = 2;"
           ],
           "\n"
         )

  test "before_after preparation renders real PNG and PDF through one dormant reusable owner" do
    {:ok, first} =
      Request.prepare(@arguments, %{"defaults" => @defaults, "languagePackAvailable" => false})

    assert first == %{
             "input" => %{
               "kind" => "before_after",
               "before" => @arguments["before"],
               "after" => @arguments["after"],
               "path" => "src/value.ts",
               "lang" => "TS",
               "title" => "Value update"
             },
             "options" => %{
               "presentation" => @defaults,
               "image" => @image,
               "expandUnchanged" => false,
               "languagePackAvailable" => false
             },
             "renderTarget" => "both",
             "mode" => "both",
             "ttlMs" => 1_800_000
           }

    {:ok, second} =
      Request.prepare(
        Map.merge(@arguments, %{"fileFormat" => "pdf", "theme" => "light", "layout" => "split"}),
        %{"defaults" => @defaults, "languagePackAvailable" => false}
      )

    assert second ==
             put_in(
               put_in(
                 put_in(first, ["options", "image", "format"], "pdf"),
                 ["options", "presentation", "theme"],
                 "light"
               ),
               ["options", "presentation", "layout"],
               "split"
             )

    exercise([first, second], "before-after")
  end

  # Upstream reference boundary: OpenClaw 488631c viewer-client omits
  # loadDiffFiles, which Pierre 1.5.2 requires for expandUnchanged on partial
  # patches. Retain the actual acceptance vector; do not coerce its option.
  @tag :upstream_blocked
  test "partial patch preparation and actual rendering retain the accepted source options" do
    {:ok, first} =
      Request.prepare(@arguments, %{"defaults" => @defaults, "languagePackAvailable" => false})

    {:ok, patch} =
      Request.prepare(
        %{
          "patch" => @patch,
          "title" => "Workspace patch",
          "mode" => "both",
          "layout" => "split",
          "theme" => "light",
          "expandUnchanged" => true,
          "fileFormat" => "pdf"
        },
        %{"defaults" => @defaults, "languagePackAvailable" => false}
      )

    assert patch == %{
             "input" => %{"kind" => "patch", "patch" => @patch, "title" => "Workspace patch"},
             "options" => %{
               "presentation" => Map.merge(@defaults, %{"layout" => "split", "theme" => "light"}),
               "image" => %{@image | "format" => "pdf"},
               "expandUnchanged" => true,
               "languagePackAvailable" => false
             },
             "renderTarget" => "both",
             "mode" => "both",
             "ttlMs" => 1_800_000
           }

    exercise([first, patch], "partial-patch")
  end

  defp exercise(plans, name) do
    staging = Path.join(System.fetch_env!("SYNAPSIS_DIFFS_STAGING"), name)
    File.mkdir_p!(staging)

    {:ok, pid} =
      PortSession.start_link(
        owner_pid: self(),
        node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
        helper_path: Path.join(System.fetch_env!("SYNAPSIS_DIFFS_CAPSULE"), "stdio.mjs"),
        chromium_executable: System.fetch_env!("SYNAPSIS_DIFFS_CHROMIUM"),
        staging_root: staging
      )

    assert %{phase: :dormant, os_pid: nil, browser_pid: nil, cleanup_confirmed: false} =
             PortSession.status(pid)

    try do
      receipts =
        Enum.with_index(plans, 1)
        |> Enum.map(fn {plan, id} ->
          assert {:ok, receipt} = PortSession.render(pid, plan, 30_000)
          assert receipt["id"] == id
          assert receipt["fileCount"] == if(plan["input"]["kind"] == "patch", do: 2, else: 1)
          assert Enum.sort(Map.keys(receipt["artifacts"])) == ["file", "html", "imageHtml"]
          bytes = verify_artifacts(receipt, staging)

          for key <- ["html", "imageHtml"] do
            assert bytes[key] =~ "shadowrootmode=\"open\""
            assert bytes[key] =~ "data-dehydrated"
            assert bytes[key] =~ "data-openclaw-diff-payload"
          end

          if plan["options"]["image"]["format"] == "png" do
            assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary-size(8), 2000::32, 640::32,
                     _::binary>> = bytes["file"]
          else
            assert_pdf(
              bytes["file"],
              if(plan["input"]["kind"] == "patch",
                do: [
                  "a.ts",
                  "b.ts",
                  "const a = 1;",
                  "const a = 2;",
                  "const extra = true;",
                  "const keep = 0;",
                  "const b = 1;",
                  "const b = 2;"
                ],
                else: ["src/value.ts", "const value = 1;", "const value = 2;"]
              )
            )
          end

          state = PortSession.status(pid)
          assert state.phase == :idle
          assert state.sequence == id
          assert state.ready["reference"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
          assert state.ready["languagePackAvailable"] == false
          {receipt, state, identity(state.os_pid), identity(state.browser_pid)}
        end)

      [{_, first, node_identity, browser_identity}, {_, second, _, _}] = receipts
      assert first.os_pid == second.os_pid
      assert first.browser_pid == second.browser_pid
      assert {:ok, closed} = PortSession.close(pid)
      assert closed.phase == :settled
      assert closed.cleanup_confirmed
      assert closed.worker_closed
      assert closed.exit_status == 0
      assert closed.browser_exit == %{"pid" => first.browser_pid, "code" => 0, "signal" => nil}
      assert identity(first.os_pid) != node_identity
      assert identity(first.browser_pid) != browser_identity

      File.write!(
        Path.join(staging, "lifecycle.json"),
        Jason.encode!(
          %{
            before: first,
            after: closed,
            node_identity: node_identity,
            browser_identity: browser_identity
          },
          pretty: true
        )
      )

      for {receipt, _, _, _} <- receipts, do: verify_artifacts(receipt, staging)

      File.write!(
        Path.join(staging, "receipts.json"),
        Jason.encode!(Enum.map(receipts, &elem(&1, 0)), pretty: true)
      )
    after
      PortSession.close(pid)
      GenServer.stop(pid)
    end
  end

  defp verify_artifacts(receipt, staging) do
    Map.new(receipt["artifacts"], fn {key, descriptor} ->
      path = Path.join(staging, descriptor["path"])
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(path)
      bytes = File.read!(path)
      assert byte_size(bytes) == descriptor["bytes"]
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == descriptor["sha256"]
      {key, bytes}
    end)
  end

  defp assert_pdf(bytes, expected) do
    # Existing PDFium helper observes the generated document independently.
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"))},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :eof,
          args:
            Enum.map(
              [System.fetch_env!("SYNAPSIS_DIFFS_PDF_HELPER"), "--port", "--timeout-ms=15000"],
              &String.to_charlist/1
            )
        ]
      )

    true =
      Port.command(
        port,
        Jason.encode!(%{"pdfBase64" => Base.encode64(bytes), "minTextChars" => 1}) <> "\n"
      )

    result = collect_pdf(port, []) |> Jason.decode!()

    assert result["metadata"]["pages"] == %{
             "processed" => [1],
             "total" => 1,
             "selection" => "automatic",
             "truncated" => false
           }

    text = String.replace(result["text"], ~r/\s/u, "")
    for literal <- expected, do: assert(text =~ String.replace(literal, ~r/\s/u, ""))
  end

  defp collect_pdf(port, chunks) do
    receive do
      {^port, {:data, bytes}} -> collect_pdf(port, [bytes | chunks])
      {^port, :eof} -> collect_pdf(port, chunks)
      {^port, {:exit_status, 0}} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {^port, {:exit_status, code}} -> flunk("PDF observer exit #{code}")
    after
      16_000 ->
        Port.close(port)
        flunk("PDF observer did not complete")
    end
  end

  defp identity(pid) when is_integer(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, raw} -> raw |> String.split(") ") |> List.last() |> String.split(" ") |> Enum.at(19)
      _ -> nil
    end
  end
end
