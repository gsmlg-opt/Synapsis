defmodule Synapsis.Agent.DiffsCleanupFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.{DiffsCleanup, DiffsDelivery}
  alias Synapsis.Diffs.{ArtifactStore, Config, PortSession, Request}

  @moduletag timeout: 90_000

  test "successful retirement is completed by the ordinary supervised cleanup sweep" do
    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-diffs359-cleanup-#{System.get_env("MIX_TEST_PARTITION", "0")}",
        Ecto.UUID.generate()
      ])

    staging = Path.join(root, "staging")
    artifacts = Path.join(root, "artifacts")
    File.mkdir_p!(staging)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, config} = Config.resolve(%{})

    assert {:ok, plan} =
             Request.prepare(
               %{
                 "before" => "one\n",
                 "after" => "two\n",
                 "mode" => "view",
                 "title" => "Retired comparison"
               },
               %{"defaults" => config["defaults"], "languagePackAvailable" => false}
             )

    binding = %{
      session_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      invocation: %{
        run_id: Ecto.UUID.generate(),
        invocation_id: Ecto.UUID.generate(),
        tool_call_id: "retired-diffs",
        tool_name: "synapsis::diffs"
      }
    }

    deadline = System.monotonic_time(:millisecond) + 60_000

    opts = [
      root: artifacts,
      staging_root: staging,
      max_bytes: 32 * 1024 * 1024,
      deadline: deadline
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

    assert {:ok, rendered} = PortSession.render(pid, plan, 30_000)
    assert {:ok, viewer} = DiffsDelivery.publish_viewer(rendered, plan, binding, opts)

    assert {:ok, %{bytes: html}} =
             DiffsDelivery.read_viewer(viewer.record.public_id, viewer.token, [])

    assert html =~ "Retired comparison"
    assert File.regular?(Path.join(artifacts, viewer.descriptor["path"]))
    assert {:ok, closed} = PortSession.close(pid)
    assert closed.cleanup_confirmed and closed.worker_closed and closed.exit_status == 0

    assert {:ok, pending} =
             ArtifactStore.retire(viewer.record.id, viewer.record.revision, deadline)

    assert pending.state == :cleanup_pending
    assert pending.root == artifacts
    assert pending.expires_at == viewer.record.expires_at
    assert {:ok, %{removed: removed, orphans_removed: _}} = DiffsCleanup.sweep(deadline)
    assert removed >= 1
    assert File.ls!(artifacts) == []
    assert {:ok, pending_after} = ArtifactStore.pending_cleanup(deadline)
    assert Enum.all?(pending_after, &(&1.id != pending.id))
    assert is_pid(Process.whereis(DiffsCleanup))
  end
end
