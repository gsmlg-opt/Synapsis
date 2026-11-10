defmodule Synapsis.Filesystem.ProvisionedNodeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Filesystem.Planner.PortSession

  # The source plans remain the frozen complete-module oracle captured on Node
  # 24.22.1. This check qualifies only the concrete locked Nix build below.
  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/edit-plans.json",
             __DIR__
           )
  @fixture_sha256 "a8336d1ff91930d238e08569fc1fb5ed23f6a542cf6dd90d9a758be1f6f604f0"
  @reference_commit "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @runtime %{
    "node" => "24.21.0",
    "v8" => "13.6.233.17-node.53",
    "unicode" => "17.0",
    "icu" => "78.3",
    "cldr" => "48.0",
    "platform" => "linux",
    "arch" => "x64"
  }
  @ordinary_ids ~w(original-snapshot reversed-request unicode-utf16 identical-noop normalized-noop bom-crlf line-ending-style fuzzy-preserves-untouched write-create write-overwrite)

  setup_all do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute
    assert String.starts_with?(node, "/nix/store/")
    assert Application.fetch_env!(:synapsis_agent, :filesystem_node) == node

    fixture_bytes = File.read!(@fixture)
    assert sha256(fixture_bytes) == @fixture_sha256
    fixture = Jason.decode!(fixture_bytes)
    assert fixture["reference"]["commit"] == @reference_commit
    assert Enum.map(fixture["cases"], & &1["id"]) == @ordinary_ids

    on_exit(fn -> assert File.read!(@fixture) == fixture_bytes end)
    {:ok, node: node, fixture: fixture}
  end

  test "provisioned Node returns all ten exact source plans and normally retires", %{
    node: node,
    fixture: fixture
  } do
    for row <- fixture["cases"] do
      assert {:ok, broker} =
               PortSession.start_link(
                 owner_pid: self(),
                 caller_pid: self(),
                 node_executable: node,
                 helper_path:
                   Path.join(:code.priv_dir(:synapsis_core), "filesystem_planner/stdio.mjs")
               )

      assert %{phase: :dormant, os_pid: nil} = PortSession.status(broker)

      request = %{
        "protocol" => 1,
        "id" => "batch224:" <> row["id"],
        "operation" => if(row["kind"] == "edit", do: "edit", else: "write_diff"),
        "input" => row["input"]
      }

      expected = %{
        "protocol" => 1,
        "id" => request["id"],
        "result" => row["result"],
        "runtime" => @runtime,
        "referenceCommit" => @reference_commit,
        "diffVersion" => "9.0.0"
      }

      deadline = System.monotonic_time(:millisecond) + 5_000
      assert {:ok, actual} = PortSession.plan(broker, request, deadline)
      assert actual == expected, row["id"]

      status = PortSession.status(broker)
      assert_completed(status)
      monitor = Process.monitor(broker)
      assert {:ok, ^status} = PortSession.close(broker)
      assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 1_000
      refute Process.alive?(broker)
    end
  end

  defp assert_completed(status) do
    assert %{
             phase: :settled,
             outcome: :completed,
             cleanup_confirmed: true,
             exit_status: 0,
             port_released: true,
             os_pid: os_pid,
             port: port
           } = status

    assert is_integer(os_pid) and os_pid > 0
    assert is_port(port)
    assert Port.info(port) == nil
    refute File.exists?("/proc/#{os_pid}")
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
