defmodule Synapsis.Filesystem.StateOperationFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Synapsis.Filesystem.Local

  @moduletag :tmp_dir

  # Independent ordinary-success literals frozen before batch256 production edits.
  # Lobster 2026.9.16 archive SHA256:
  # ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1
  # Source: dist/src/state/store.js withFileLock/writeStateJson/diffAndStore;
  # dist/src/state/atomic_file.js writeFileAtomic.
  # API: parent-frozen session256 test-contract.json plus named status clarification.
  # Actual file/directory sync call observation is separately parent-owned.

  test "locked read returns the exact existing byte capture after later publication", %{
    tmp_dir: root
  } do
    path = Path.join(root, "captured.bin")
    before = <<0, 255, 128, 65, 13, 10, 66, 0>>
    after_bytes = <<255, 0, 67, 10>>
    File.write!(path, before)

    assert {:ok, captured} = run_closed(root, "captured.bin", :read_locked)

    assert captured === %{
             before: %{exists: true, bytes: before},
             value: nil,
             publication: :not_applicable,
             file_sync: :not_applicable,
             directory_sync: :not_applicable,
             cleanup_confirmed: true
           }

    assert File.read!(path) === before

    assert {:ok, result} =
             run_closed(root, "captured.bin", {:write_always, after_bytes})

    assert result === published(:not_captured, nil)
    assert File.read!(path) === after_bytes
    assert captured.before === %{exists: true, bytes: before}
    assert File.ls!(root) === ["captured.bin"]
  end

  test "always-write creates complete bytes and replaces changed and identical snapshots", %{
    tmp_dir: root
  } do
    path = Path.join(root, "published.bin")
    original = :binary.copy(<<0, 255, 128, 65, 13, 10>>, 20_000)
    replacement = :binary.copy(<<255, 0, 66, 10>>, 17_000)

    assert {:ok, created} =
             run_closed(root, "published.bin", {:write_always, original})

    assert created === published(:not_captured, nil)
    assert File.read!(path) === original
    original_inode = File.stat!(path).inode
    {:ok, original_handle} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

    try do
      assert {:ok, replaced} =
               run_closed(root, "published.bin", {:write_always, replacement})

      assert replaced === published(:not_captured, nil)
      assert File.read!(path) === replacement
      replacement_inode = File.stat!(path).inode
      assert replacement_inode != original_inode
      assert {:ok, ^original} = :file.pread(original_handle, 0, byte_size(original))

      {:ok, replacement_handle} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

      try do
        assert {:ok, identical} =
                 run_closed(root, "published.bin", {:write_always, replacement})

        assert identical === published(:not_captured, nil)
        assert File.read!(path) === replacement
        assert File.stat!(path).inode != replacement_inode

        assert {:ok, ^replacement} =
                 :file.pread(replacement_handle, 0, byte_size(replacement))

        assert {:ok, ^original} = :file.pread(original_handle, 0, byte_size(original))
      after
        :ok = :file.close(replacement_handle)
      end
    after
      :ok = :file.close(original_handle)
    end

    assert File.ls!(root) === ["published.bin"]
  end

  test "locked transition captures once and preserves the original callback value", %{
    tmp_dir: root
  } do
    path = Path.join(root, "transition.bin")
    before = <<0, 255, 13, 10, 65>>
    after_bytes = <<66, 0, 128, 10>>
    File.write!(path, before)
    caller = self()
    invocation = make_ref()
    value = %{identity: make_ref(), owner: caller, retained: [before, :ordinary_domain_value]}
    before_inode = File.stat!(path).inode
    {:ok, before_handle} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

    callback = fn capture ->
      send(caller, {invocation, capture})
      assert File.dir?(path <> ".lock")
      assert File.read!(path) === before

      {:ok, %{write: after_bytes, rollback: {:replace, before}, value: value}}
    end

    try do
      assert {:ok, result} =
               run_closed(root, "transition.bin", {:transition_locked, callback})

      assert result === published(%{exists: true, bytes: before}, value)
      assert_receive {^invocation, %{exists: true, bytes: ^before}}, 1_000
      refute_receive {^invocation, _}, 0
      assert File.read!(path) === after_bytes
      assert File.stat!(path).inode != before_inode
      assert {:ok, ^before} = :file.pread(before_handle, 0, byte_size(before))
    after
      :ok = :file.close(before_handle)
    end

    unchanged_inode = File.stat!(path).inode
    {:ok, unchanged_handle} = :file.open(String.to_charlist(path), [:read, :binary, :raw])
    unchanged_invocation = make_ref()

    try do
      unchanged_callback = fn capture ->
        send(caller, {unchanged_invocation, capture})

        {:ok,
         %{write: after_bytes, rollback: {:replace, after_bytes}, value: :unchanged_domain_value}}
      end

      assert {:ok, result} =
               run_closed(root, "transition.bin", {:transition_locked, unchanged_callback})

      assert result ===
               published(%{exists: true, bytes: after_bytes}, :unchanged_domain_value)

      assert_receive {^unchanged_invocation, %{exists: true, bytes: ^after_bytes}}, 1_000
      refute_receive {^unchanged_invocation, _}, 0
      assert File.read!(path) === after_bytes
      assert File.stat!(path).inode != unchanged_inode
      assert {:ok, ^after_bytes} = :file.pread(unchanged_handle, 0, byte_size(after_bytes))
    after
      :ok = :file.close(unchanged_handle)
    end

    assert File.ls!(root) === ["transition.bin"]
  end

  test "ordinary same-path transitions serialize capture through complete publication", %{
    tmp_dir: root
  } do
    path = Path.join(root, "serial.bin")
    initial = "initial\r\n"
    first_bytes = "first\n"
    second_bytes = "second\n"
    File.write!(path, initial)
    caller = self()

    first =
      Task.async(fn ->
        callback = fn capture ->
          assert capture === %{exists: true, bytes: initial}
          assert File.dir?(path <> ".lock")
          send(caller, {:first_callback, self()})

          receive do
            :publish_first ->
              {:ok, %{write: first_bytes, rollback: {:replace, initial}, value: :first_value}}
          end
        end

        run_closed(root, "serial.bin", {:transition_locked, callback})
      end)

    assert_receive {:first_callback, first_worker}, 1_000
    on_exit(fn -> send(first_worker, :publish_first) end)
    assert File.read!(path) === initial

    second =
      Task.async(fn ->
        send(caller, {:second_runner, self()})

        receive do
          :run_second ->
            callback = fn capture ->
              send(caller, {:second_capture, capture})

              {:ok,
               %{write: second_bytes, rollback: {:replace, first_bytes}, value: :second_value}}
            end

            run_closed(root, "serial.bin", {:transition_locked, callback})
        end
      end)

    assert_receive {:second_runner, second_runner}, 1_000
    on_exit(fn -> send(second_runner, :run_second) end)
    :erlang.trace_pattern({Local, :run_state_operation, 2}, true, [:local])
    :erlang.trace(second_runner, true, [:call, {:tracer, caller}])

    on_exit(fn ->
      :erlang.trace_pattern({Local, :run_state_operation, 2}, false, [:local])
    end)

    send(second_runner, :run_second)

    assert_receive {:trace, ^second_runner, :call,
                    {Local, :run_state_operation, [_ticket, {:transition_locked, _callback}]}},
                   1_000

    send(first_worker, :publish_first)

    assert Task.await(first, 5_000) ===
             {:ok, published(%{exists: true, bytes: initial}, :first_value)}

    assert Task.await(second, 5_000) ===
             {:ok, published(%{exists: true, bytes: first_bytes}, :second_value)}

    assert_receive {:second_capture, %{exists: true, bytes: ^first_bytes}}, 1_000
    assert File.read!(path) === second_bytes
    assert File.ls!(root) === ["serial.bin"]
  end

  test "native registration precedes the run and release closes the live guardian once", %{
    tmp_dir: root
  } do
    registry = start_supervised!({ResourceRegistry, cleanup_timeout: 5_000})
    path = Path.join(root, "registered.bin")
    before = <<0, 65, 13, 10>>
    after_bytes = <<255, 66, 10>>
    File.write!(path, before)
    caller = self()
    owner_id = "state-operation-positive-owner"

    assert {:ok, ticket} =
             Local.start_state_operation(root, "registered.bin",
               deadline: deadline(),
               owner_pid: caller
             )

    guardian = Local.state_operation_owner(ticket)
    assert is_pid(guardian)
    assert Process.alive?(guardian)
    monitor = Process.monitor(guardian)
    assert {:ok, %{phase: :dormant, evidence: nil}} = Local.state_operation_status(ticket)
    assert File.read!(path) === before
    assert File.ls!(root) === ["registered.bin"]

    cleanup = fn ->
      send(caller, {:registry_cleanup_entered, self(), Process.alive?(guardian)})
      result = Local.close_state_operation(ticket)
      send(caller, {:registry_cleanup_closed, self(), result, Process.alive?(guardian)})
      result
    end

    assert {:ok, handle} =
             ResourceRegistry.register(registry, owner_id, :workflow_state_io, guardian,
               incarnation: 1,
               owner_pid: caller,
               cleanup: cleanup
             )

    assert handle.kind === :workflow_state_io
    assert handle.owner_id === owner_id
    assert handle.incarnation === 1
    assert {:ok, ^guardian} = ResourceRegistry.fetch(registry, handle, owner_id)
    assert {:ok, %{phase: :dormant, evidence: nil}} = Local.state_operation_status(ticket)
    assert File.read!(path) === before
    assert File.ls!(root) === ["registered.bin"]

    callback = fn capture ->
      assert {:ok, ^guardian} = ResourceRegistry.fetch(registry, handle, owner_id)
      send(caller, {:registered_callback, capture})
      {:ok, %{write: after_bytes, rollback: {:replace, before}, value: :registered_domain_value}}
    end

    assert {:ok, result} = Local.run_state_operation(ticket, {:transition_locked, callback})
    assert result === published(%{exists: true, bytes: before}, :registered_domain_value)
    assert_receive {:registered_callback, %{exists: true, bytes: ^before}}, 1_000
    assert File.read!(path) === after_bytes
    assert Process.alive?(guardian)
    assert {:ok, %{phase: :settled}} = Local.state_operation_status(ticket)

    assert {:ok, :ok} = ResourceRegistry.release(registry, handle, owner_id)
    assert_receive {:registry_cleanup_entered, cleanup_worker, true}, 1_000
    assert_receive {:registry_cleanup_closed, ^cleanup_worker, :ok, false}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 1_000

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(registry, handle, owner_id)

    refute Process.alive?(guardian)
    refute_receive {:registry_cleanup_entered, _, _}, 0
    assert File.ls!(root) === ["registered.bin"]
  end

  defp run_closed(root, path, request) do
    assert {:ok, ticket} =
             Local.start_state_operation(root, path, deadline: deadline(), owner_pid: self())

    guardian = Local.state_operation_owner(ticket)
    assert is_pid(guardian)
    assert Process.alive?(guardian)
    monitor = Process.monitor(guardian)
    assert {:ok, %{phase: :dormant, evidence: nil}} = Local.state_operation_status(ticket)
    result = Local.run_state_operation(ticket, request)
    assert Process.alive?(guardian)
    assert {:ok, %{phase: :settled}} = Local.state_operation_status(ticket)
    assert :ok = Local.close_state_operation(ticket)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 1_000
    refute Process.alive?(guardian)
    result
  end

  defp published(before, value) do
    %{
      before: before,
      value: value,
      publication: :published,
      file_sync: :confirmed,
      directory_sync: :confirmed,
      cleanup_confirmed: true
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 10_000
end
