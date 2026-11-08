defmodule Synapsis.Workspace.DiffArtifactsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Diffs.{PortSession, Request}
  alias Synapsis.Workspace.DiffArtifacts

  @max_bytes 32 * 1024 * 1024
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

  setup do
    partition = System.get_env("MIX_TEST_PARTITION", "0")

    root =
      Path.join(
        System.tmp_dir!(),
        "synapsis-diffs-workspace-#{partition}-#{Ecto.UUID.generate()}"
      )

    staging = Path.join(root, "staging")
    published = Path.join(root, "published")
    File.mkdir_p!(staging)
    File.mkdir_p!(published)
    on_exit(fn -> File.rm_rf!(root) end)
    %{staging: staging, root: published}
  end

  @tag timeout: 120_000
  test "publishes actual renderer HTML as gzip and PNG/PDF with exact hashes and readback", %{
    staging: staging,
    root: root
  } do
    assert {:ok, renderer} =
             PortSession.start_link(
               owner_pid: self(),
               node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
               helper_path: Path.join(System.fetch_env!("SYNAPSIS_DIFFS_CAPSULE"), "stdio.mjs"),
               chromium_executable: System.fetch_env!("SYNAPSIS_DIFFS_CHROMIUM"),
               staging_root: staging
             )

    try do
      descriptors =
        for format <- ~w(png pdf) do
          assert {:ok, plan} =
                   Request.prepare(
                     %{
                       "before" => "const value = 1;\n",
                       "after" => "const value = 2;\n",
                       "path" => "src/value.ts",
                       "title" => "Value update",
                       "mode" => "both",
                       "fileFormat" => format
                     },
                     %{"defaults" => @defaults, "languagePackAvailable" => false}
                   )

          assert {:ok, rendered} = PortSession.render(renderer, plan, 30_000)
          html_receipt = rendered["artifacts"]["html"]
          html = staged_bytes(staging, html_receipt)
          assert html =~ "data-openclaw-diff-payload"
          assert html =~ "shadowrootmode=\"open\""
          viewer_id = public_id()

          assert {:ok, viewer} =
                   DiffArtifacts.put_viewer(root, viewer_id, html, max_bytes: @max_bytes)

          assert viewer["version"] == 1
          assert viewer["kind"] == "viewer"
          assert viewer["artifactId"] == viewer_id
          assert viewer["format"] == "html"
          assert viewer["mimeType"] == "text/html; charset=utf-8"
          assert viewer["encoding"] == "gzip"
          assert viewer["path"] == Path.join(viewer_id, "viewer.html.gz")
          assert viewer["decodedBytes"] == byte_size(html)
          gzip = File.read!(Path.join(root, viewer["path"]))
          assert <<31, 139, _::binary>> = gzip
          assert :zlib.gunzip(gzip) == html
          assert viewer["bytes"] == byte_size(gzip)
          assert viewer["sha256"] == sha256(gzip)
          assert_readback(root, viewer, html)

          staged = rendered["artifacts"]["file"]
          file = staged_bytes(staging, staged)
          file_id = public_id()

          assert {:ok, descriptor} =
                   DiffArtifacts.put_file(root, file_id, format, staged,
                     staging_root: staging,
                     max_bytes: @max_bytes
                   )

          assert descriptor["version"] == 1
          assert descriptor["kind"] == "file"
          assert descriptor["artifactId"] == file_id
          assert descriptor["format"] == format
          assert descriptor["mimeType"] == staged["mimeType"]
          assert descriptor["path"] == Path.join(file_id, "preview.#{format}")
          assert descriptor["bytes"] == byte_size(file)
          assert descriptor["sha256"] == sha256(file)

          path = DiffArtifacts.file_path(root, file_id, format)
          assert path == Path.join([root, file_id, "preview.#{format}"])
          assert File.read!(path) == file
          assert_readback(root, descriptor, file)
          [viewer, descriptor]
        end
        |> List.flatten()

      assert length(Enum.uniq_by(descriptors, & &1["artifactId"])) == 4
      assert {:ok, closed} = PortSession.close(renderer)
      assert closed.phase == :settled
      assert closed.cleanup_confirmed
      assert closed.worker_closed
      assert closed.exit_status == 0

      for descriptor <- descriptors do
        assert :ok = DiffArtifacts.remove(root, descriptor["artifactId"], max_bytes: @max_bytes)
      end

      assert File.ls!(root) == []
    after
      if Process.alive?(renderer) do
        PortSession.close(renderer)
        GenServer.stop(renderer)
      end
    end
  end

  defp assert_readback(root, descriptor, bytes) do
    portable = Jason.decode!(Jason.encode!(descriptor))
    assert portable == descriptor

    assert {:ok, %{bytes: ^bytes, descriptor: ^portable}} =
             DiffArtifacts.read(portable, root: root, max_bytes: @max_bytes)
  end

  defp staged_bytes(staging, receipt) do
    bytes = File.read!(Path.join(staging, receipt["path"]))
    assert byte_size(bytes) == receipt["bytes"]
    assert sha256(bytes) == receipt["sha256"]
    bytes
  end

  defp public_id, do: Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
