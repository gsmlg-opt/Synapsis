defmodule Synapsis.Filesystem.PlannerEffectFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Filesystem.Local
  alias Synapsis.Filesystem.Planner.PortSession

  @moduletag :tmp_dir

  # Frozen from complete pinned original modules and the genuine batch201 fixture
  # before batch203 production implementation. No production result builds an oracle.
  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/edit-plans.json",
             __DIR__
           )
  @fixture_sha256 "a8336d1ff91930d238e08569fc1fb5ed23f6a542cf6dd90d9a758be1f6f604f0"
  @reference_commit "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @runtime %{
    "node" => "24.22.1",
    "v8" => "13.6.233.17-node.58",
    "unicode" => "17.0",
    "icu" => "78.3",
    "cldr" => "48.0",
    "platform" => "linux",
    "arch" => "x64"
  }
  @ordinary_ids ~w(original-snapshot reversed-request unicode-utf16 identical-noop normalized-noop bom-crlf line-ending-style fuzzy-preserves-untouched write-create write-overwrite)

  setup_all do
    # The caller supplies the qualified Node explicitly. Never resolve it from PATH
    # or skip this contract when the test configuration is incomplete.
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    fixture_bytes = File.read!(@fixture)
    assert sha256(fixture_bytes) == @fixture_sha256
    fixture = Jason.decode!(fixture_bytes)
    assert fixture["reference"]["commit"] == @reference_commit
    assert Enum.map(fixture["cases"], & &1["id"]) == @ordinary_ids

    on_exit(fn -> assert File.read!(@fixture) == fixture_bytes end)
    {:ok, node: node, fixture: fixture}
  end

  test "real packaged planner returns all ten exact source plans and retires its OS process", %{
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
        "id" => "batch203:" <> row["id"],
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

      # A future absolute monotonic deadline bounds the ordinary call only.
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

  test "real file edits preserve source envelopes, original-snapshot semantics and persisted bytes",
       %{
         tmp_dir: root,
         node: node,
         fixture: fixture
       } do
    for row <- fixture["cases"], row["kind"] == "edit" do
      directory = Path.join(root, row["id"])
      File.mkdir_p!(directory)
      target = Path.join(directory, "edit.txt")
      input = row["input"]
      plan = row["result"]
      File.write!(target, input["content"])

      expected =
        if plan["changed"] do
          %{
            content: [
              %{
                type: "text",
                text: "Successfully replaced #{plan["editCount"]} block(s) in edit.txt."
              }
            ],
            details: Map.put(receipt(plan["receipt"]), :changed, true)
          }
        else
          %{content: [%{type: "text", text: plan["message"]}], details: %{changed: false}}
        end

      assert {:ok, actual} =
               Local.edit_text(directory, "edit.txt", input["edits"],
                 node_executable: node,
                 observer_pid: self()
               )

      assert actual == expected, row["id"]
      expected_bytes = if plan["changed"], do: plan["content"], else: input["content"]
      assert File.read!(target) == expected_bytes, row["id"]
      assert File.stat!(target).type == :regular
      assert_local_planner_retired()
    end
  end

  test "real file create and overwrite retain genuine complete receipts and byte-count messages",
       %{
         tmp_dir: root,
         node: node,
         fixture: fixture
       } do
    for row <- fixture["cases"], row["kind"] == "write" do
      directory = Path.join(root, row["id"])
      File.mkdir_p!(directory)
      target = Path.join(directory, "write.txt")
      input = row["input"]
      if Map.has_key?(input, "beforeText"), do: File.write!(target, input["beforeText"])

      expected = %{
        content: [%{type: "text", text: "Successfully wrote 4 bytes to write.txt"}],
        details:
          row["result"]
          |> receipt()
          |> Map.merge(%{changed: true, created: input["created"]})
      }

      assert {:ok, actual} =
               Local.write_text(directory, "write.txt", input["content"],
                 node_executable: node,
                 observer_pid: self()
               )

      assert actual == expected, row["id"]
      assert File.read!(target) == "new\n"
      assert File.stat!(target).type == :regular
      assert_local_planner_retired()
    end
  end

  # W3 comes directly from write.ts's same-byte precheck and textResult, rather
  # than pretending a pure write-diff fixture observed a tool-level no-op.
  test "identical write returns the source no-op envelope and retains exact bytes", %{
    tmp_dir: root,
    node: node
  } do
    target = Path.join(root, "write.txt")
    File.write!(target, "new\n")

    expected = %{
      content: [
        %{
          type: "text",
          text: "No changes made to write.txt. The file already has identical content."
        }
      ],
      details: %{changed: false}
    }

    assert {:ok, ^expected} =
             Local.write_text(root, "write.txt", "new\n",
               node_executable: node,
               observer_pid: self()
             )

    assert File.read!(target) == "new\n"
    assert File.stat!(target).type == :regular
  end

  test "internal domain writes and zero-based read pages retain their existing contract", %{
    tmp_dir: root
  } do
    assert {:ok, %{status: "created", path: "domain.txt", bytes: 14}} =
             Local.perform(root, :file_write, %{
               "path" => "domain.txt",
               "content" => "one\ntwo\nthree\n"
             })

    assert File.read!(Path.join(root, "domain.txt")) == "one\ntwo\nthree\n"

    assert {:ok,
            %{
              path: "domain.txt",
              content: "two\n",
              offset: 1,
              next_offset: 2,
              truncated: true,
              partial_line: false
            }} =
             Local.perform(root, :file_read, %{
               "path" => "domain.txt",
               "offset" => 1,
               "limit" => 1
             })
  end

  defp receipt(%{"diff" => diff, "patch" => patch, "firstChangedLine" => first} = receipt) do
    assert map_size(receipt) == 3
    %{diff: diff, patch: patch, firstChangedLine: first}
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

  defp assert_local_planner_retired do
    assert_receive {:filesystem_planner, broker, status}, 1_000
    assert is_pid(broker)
    assert_completed(status)
    refute Process.alive?(broker)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
