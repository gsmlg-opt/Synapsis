defmodule Synapsis.Agent.DiffsDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.DiffsDelivery
  alias Synapsis.Diffs.{Config, PortSession, Request}
  alias Synapsis.Runtime.Store

  @moduletag timeout: 120_000

  setup do
    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-diffs359-delivery-#{System.get_env("MIX_TEST_PARTITION", "0")}",
        Ecto.UUID.generate()
      ])

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "real viewer and PNG publish independent receipts and read from their original root", %{
    root: root
  } do
    staging = Path.join(root, "staging")
    artifacts = Path.join(root, "original-artifacts")
    File.mkdir_p!(staging)
    binding = delivery_binding()
    assert {:ok, config} = Config.resolve(%{})

    assert {:ok, plan} =
             Request.prepare(
               %{
                 "before" => "const value = 1;\n",
                 "after" => "const value = 2;\n",
                 "path" => "src/value.ts",
                 "title" => "Value update",
                 "mode" => "both"
               },
               %{
                 "defaults" => config["defaults"],
                 "languagePackAvailable" => false,
                 "context" => %{"agentId" => binding.agent_id, "sessionId" => binding.session_id}
               }
             )

    opts = [
      root: artifacts,
      staging_root: staging,
      max_bytes: 32 * 1024 * 1024,
      deadline: System.monotonic_time(:millisecond) + 90_000
    ]

    pid =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
         helper_path: Application.app_dir(:synapsis_core, "priv/diffs_renderer/stdio.mjs"),
         chromium_executable: System.fetch_env!("SYNAPSIS_DIFFS_CHROMIUM"),
         staging_root: staging}
      )

    assert {:ok, rendered_view} =
             PortSession.render(pid, Map.put(plan, "renderTarget", "viewer"), 30_000)

    assert {:ok, viewer} = DiffsDelivery.publish_viewer(rendered_view, plan, binding, opts)
    assert viewer.record.state == :complete
    assert viewer.record.kind == :viewer
    assert viewer.record.root == artifacts
    assert viewer.record.expires_at - viewer.record.created_at == plan["ttlMs"]
    assert Regex.match?(~r/\A[0-9a-f]{20}\z/, viewer.record.public_id)
    assert Regex.match?(~r/\A[0-9a-f]{48}\z/, viewer.token)
    assert viewer.viewer_path == "/plugins/diffs/view/#{viewer.record.public_id}/#{viewer.token}"

    assert {:ok, viewer_bytes} =
             DiffsDelivery.read_viewer(viewer.record.public_id, viewer.token, [])

    assert viewer_bytes.descriptor == viewer.descriptor
    assert viewer_bytes.bytes =~ "Value update"
    assert viewer_bytes.bytes =~ "data-openclaw-diff-payload"
    assert viewer_bytes.bytes =~ "shadowrootmode=\"open\""

    assert :zlib.gunzip(File.read!(Path.join(artifacts, viewer.descriptor["path"]))) ==
             viewer_bytes.bytes

    assert {:ok, reservation} = DiffsDelivery.reserve_file(plan, binding, opts)
    assert reservation.public_id != viewer.record.public_id
    assert reservation.expires_at - reservation.created_at == plan["ttlMs"]

    assert {:ok, rendered_file} =
             PortSession.render(pid, Map.put(plan, "renderTarget", "image"), 30_000)

    assert {:ok, file} =
             DiffsDelivery.complete_file(reservation, rendered_file["artifacts"]["file"], opts)

    assert file.record.state == :complete
    assert file.record.public_id == reservation.public_id
    assert file.record.expires_at == reservation.expires_at
    assert Path.basename(file.file_path) == "preview.png"
    assert file.file_path == Path.join(artifacts, file.descriptor["path"])
    assert %{"version" => 1, "session_id" => session_id, "id" => delivery_id} = file.reference
    assert session_id == binding.session_id
    assert {:ok, ^delivery_id} = Ecto.UUID.cast(delivery_id)
    assert {:ok, fact} = Store.get_fact(session_id, :diffs_file_delivery, delivery_id)
    assert fact.root == artifacts
    assert fact.invocation == binding.invocation
    assert fact.expires_at == reservation.expires_at

    assert {:ok, bytes} = DiffsDelivery.read_file(session_id, delivery_id, [])
    assert bytes.descriptor == file.descriptor
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = bytes.bytes
    assert bytes.bytes == File.read!(file.file_path)
    assert byte_size(bytes.bytes) == file.descriptor["bytes"]

    assert Base.encode16(:crypto.hash(:sha256, bytes.bytes), case: :lower) ==
             file.descriptor["sha256"]

    assert {:ok, attachment} = DiffsDelivery.resolve_attachment(session_id, file.file_path, [])
    assert attachment.file_path == file.file_path
    assert attachment.bytes == bytes.bytes

    # A new root in the current composition cannot reroot a published receipt.
    replacement = Path.join(root, "replacement-artifacts")
    File.mkdir_p!(replacement)
    assert {:ok, reread} = DiffsDelivery.read_file(session_id, delivery_id, root: replacement)
    assert reread == bytes
    assert File.ls!(replacement) == []

    assert {:ok, html_again} =
             DiffsDelivery.read_viewer(viewer.record.public_id, viewer.token, root: replacement)

    assert html_again == viewer_bytes
    assert {:ok, ^fact} = Store.get_fact(session_id, :diffs_file_delivery, delivery_id)

    assert {:ok, closed} = PortSession.close(pid)
    assert closed.cleanup_confirmed and closed.worker_closed
    assert closed.exit_status == 0
    assert :ok = DiffsDelivery.remove_artifact(viewer.record, [])
    assert :ok = DiffsDelivery.remove_artifact(file.record, [])
    assert File.ls!(artifacts) == []
  end

  test "URL precedence preserves a request prefix and independent file reference", %{root: _root} do
    viewer = %{
      viewer_path: "/plugins/diffs/view/0123456789abcdef0123/" <> String.duplicate("ab", 24)
    }

    urls = %{
      base_url: "https://request.example/prefix/",
      viewer_base_url: "https://configured.example/base",
      host_origin: "http://127.0.0.1:4657"
    }

    assert {:ok, request_url} = DiffsDelivery.viewer_url(viewer, urls)
    assert request_url == "https://request.example/prefix" <> viewer.viewer_path
    assert {:ok, configured_url} = DiffsDelivery.viewer_url(viewer, %{urls | base_url: nil})
    assert configured_url == "https://configured.example/base" <> viewer.viewer_path

    assert {:ok, local_url} =
             DiffsDelivery.viewer_url(viewer, %{urls | base_url: nil, viewer_base_url: nil})

    assert local_url == urls.host_origin <> viewer.viewer_path

    reference = %{
      "version" => 1,
      "session_id" => Ecto.UUID.generate(),
      "id" => Ecto.UUID.generate()
    }

    assert {:ok, url} = DiffsDelivery.file_url(reference)
    assert url == "/api/diffs/files/#{reference["session_id"]}/#{reference["id"]}"
  end

  defp delivery_binding do
    %{
      session_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      invocation: %{
        run_id: Ecto.UUID.generate(),
        invocation_id: Ecto.UUID.generate(),
        tool_call_id: "ordinary-diffs",
        tool_name: "synapsis::diffs"
      }
    }
  end
end
