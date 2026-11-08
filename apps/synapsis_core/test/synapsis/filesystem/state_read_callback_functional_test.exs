defmodule Synapsis.Filesystem.StateReadCallbackFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.{Access, Local}
  alias Synapsis.Workflow.Provenance.Owner
  alias Synapsis.Workflow.{Live, Machine, Pipeline, Value}

  @moduletag :tmp_dir
  @timeout 5_000
  @text "{\n  \"model\": \"fixture\",\n  \"usage\": {\n    \"inputTokens\": 2\n  },\n  \"answer\": \"ok\"\n}\n"

  # Independently frozen ordinary tests. Local performs real file IO and lock
  # ordering. Private marks and Machine state ACKs below are internal semantic
  # fixtures, not an admitted Agent/journal/provider workflow or billing claim.

  test "locked read callback preserves exact bytes and private terms without publishing", %{
    tmp_dir: root
  } do
    path = Path.join(root, "captured.bin")
    bytes = <<0, 255, 128, 65, 13, 10, 66, 0>>
    File.write!(path, bytes)
    inode = File.stat!(path).inode
    caller = self()
    invocation = make_ref()
    private = %{identity: make_ref(), owner: caller, retained: [bytes, :domain_value]}

    callback = fn capture ->
      assert capture === %{exists: true, bytes: bytes}
      assert self() != caller
      assert File.dir?(path <> ".lock")
      assert File.regular?(Path.join(path <> ".lock", "owner"))
      assert File.read!(path) === bytes
      assert File.stat!(path).inode == inode
      send(caller, {invocation, self(), capture})
      {:ok, private}
    end

    assert {:ok, result} = run_closed(root, "captured.bin", {:read_locked, callback})
    assert result === read_summary(bytes, private)
    assert_receive {^invocation, callback_pid, %{exists: true, bytes: ^bytes}}, 1_000
    refute Process.alive?(callback_pid)
    refute_receive {^invocation, _, _}, 0
    assert File.read!(path) === bytes
    assert File.stat!(path).inode == inode
    assert File.ls!(root) == ["captured.bin"]

    # Existing byte-only reads retain their exact successful summary contract.
    assert {:ok, plain} = run_closed(root, "captured.bin", :read_locked)
    assert plain === read_summary(bytes, nil)
    assert File.stat!(path).inode == inode
    assert File.ls!(root) == ["captured.bin"]
  end

  test "actual Live state-get decode and carry complete inside the Local callback", %{
    tmp_dir: root
  } do
    owner = start_supervised!({Owner, name: nil})
    path = Path.join(root, "state.json")
    File.write!(path, @text)
    inode = File.stat!(path).inode
    remember_existing(owner, path, "call-A")
    {binding, pending, request} = pending(owner, "state.get record", [], Value.new())
    driver = self()
    token = make_ref()

    callback = fn capture ->
      assert capture === %{exists: true, bytes: @text}
      assert self() != driver
      assert File.dir?(path <> ".lock")

      event = %{
        "id" => request["id"],
        "kind" => "state_get",
        "result" => "ok",
        "text" => capture.bytes
      }

      context = %{request_id: request["id"], lexical_path: path}

      assert {:ok, {:continue, next}, next_binding} =
               Live.advance(binding, pending, event, context, @timeout)

      read = read_root(next)
      assert_mark(next_binding, read, "call-A", true)
      assert_mark(next_binding, Value.object_get(read, "usage", next["heap"]), "call-A", true)
      assert File.dir?(path <> ".lock")

      {:ok,
       %{
         token: token,
         driver: driver,
         callback: self(),
         machine: next,
         binding: next_binding,
         root: read
       }}
    end

    assert {:ok, result} = run_closed(root, "state.json", {:read_locked, callback})
    domain = result.value
    assert result === read_summary(@text, domain)
    assert domain.token === token
    assert domain.driver == driver
    assert domain.callback != driver
    refute Process.alive?(domain.callback)
    # Live.open ran in this driver before Local's separate callback existed.
    # Its lease remains usable after normal callback retirement.
    assert_mark(domain.binding, domain.root, "call-A", true)
    {final, binding} = complete(domain.binding, domain.machine)
    assert final["items"] == [domain.root]
    assert Live.release(binding, @timeout) == :ok
    assert File.read!(path) === @text
    assert File.stat!(path).inode == inode
    assert File.ls!(root) == ["state.json"]
  end

  test "same-path writer waits for complete read callback before identical-byte publication and remember",
       %{tmp_dir: root} do
    owner = start_supervised!({Owner, name: nil})
    path = Path.join(root, "serial.json")
    File.write!(path, @text)
    original_inode = File.stat!(path).inode
    remember_existing(owner, path, "call-A")

    {read_binding, read_pending, read_request} =
      pending(owner, "state.get record", [], Value.new())

    {write_root, write_heap} = item()

    {write_binding, write_pending, write_request} =
      pending(owner, "state.set record", [write_root], write_heap, "call-B")

    assert write_request["text"] == @text
    driver = self()
    gate = make_ref()

    reader =
      Task.async(fn ->
        callback = fn capture ->
          assert capture === %{exists: true, bytes: @text}
          assert File.dir?(path <> ".lock")
          assert File.stat!(path).inode == original_inode

          event = %{
            "id" => read_request["id"],
            "kind" => "state_get",
            "result" => "ok",
            "text" => capture.bytes
          }

          context = %{request_id: read_request["id"], lexical_path: path}

          assert {:ok, {:continue, next}, binding} =
                   Live.advance(read_binding, read_pending, event, context, @timeout)

          read = read_root(next)
          assert_mark(binding, read, "call-A", true)

          domain = %{
            machine: next,
            binding: binding,
            root: read,
            callback: self(),
            driver: driver
          }

          send(driver, {gate, :read_carried, domain})

          receive do
            {^gate, :finish_read} ->
              assert File.dir?(path <> ".lock")
              assert File.stat!(path).inode == original_inode
              assert_mark(binding, read, "call-A", true)
              {:ok, domain}
          end
        end

        run_closed(root, "serial.json", {:read_locked, callback})
      end)

    assert_receive {^gate, :read_carried, domain}, 1_000
    callback_pid = domain.callback
    assert callback_pid != driver
    callback_monitor = Process.monitor(callback_pid)
    on_exit(fn -> send(callback_pid, {gate, :finish_read}) end)

    writer =
      Task.async(fn ->
        receive do
          {^gate, :run_writer} ->
            assert {:ok, publication} = run_closed(root, "serial.json", {:write_always, @text})
            assert publication === published()
            refute Process.alive?(callback_pid)
            assert File.read!(path) === @text
            assert File.stat!(path).inode != original_inode
            event = %{"id" => write_request["id"], "kind" => "state_set", "result" => "ok"}
            context = %{request_id: write_request["id"], lexical_path: path}

            assert {:ok, {:continue, next}, binding} =
                     Live.advance(write_binding, write_pending, event, context, @timeout)

            send(driver, {gate, :writer_remembered})
            {publication, binding, next}
        end
      end)

    # Observe the writer's actual Access acquisition call, inherited only by
    # this Task's children, before releasing the reader's callback gate. There
    # is no arbitrary sleep or fake queued driver.
    :erlang.trace_pattern({Access, :acquire, 2}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(writer.pid, true, [:call, :set_on_spawn, {:tracer, driver}])

    on_exit(fn ->
      :erlang.trace_pattern({Access, :acquire, 2}, false, [:local])
      send(writer.pid, {gate, :run_writer})
    end)

    try do
      send(writer.pid, {gate, :run_writer})
      assert_receive {:trace, writer_worker, :call, {Access, :acquire, [_lease, keys]}}, 1_000
      assert keys == [root]
      assert Process.alive?(callback_pid)
      assert File.dir?(path <> ".lock")
      assert File.read!(path) === @text
      refute_receive {:trace, ^writer_worker, :return_from, {Access, :acquire, 2}, :ok}, 0
      refute_receive {^gate, :writer_remembered}, 0

      send(callback_pid, {gate, :finish_read})
      assert_receive {:DOWN, ^callback_monitor, :process, ^callback_pid, :normal}, 1_000
      assert {:ok, read_result} = Task.await(reader, @timeout)
      assert read_result === read_summary(@text, domain)
      assert_receive {:trace, ^writer_worker, :return_from, {Access, :acquire, 2}, :ok}, 1_000
      {_publication, binding, next} = Task.await(writer, @timeout)
      assert_receive {^gate, :writer_remembered}, 1_000
      assert_mark(domain.binding, domain.root, "call-A", true)
      {_final, read_binding} = complete(domain.binding, domain.machine)
      assert Live.release(read_binding, @timeout) == :ok
      {_final, write_binding} = complete(binding, next)
      assert Live.release(write_binding, @timeout) == :ok

      # A later real Local capture of the same bytes now carries B. The earlier
      # root keeps its independently allocated A identity until normal release.
      {binding, pending, request} = pending(owner, "state.get record", [], Value.new())

      callback = fn capture ->
        assert File.dir?(path <> ".lock")

        event = %{
          "id" => request["id"],
          "kind" => "state_get",
          "result" => "ok",
          "text" => capture.bytes
        }

        assert {:ok, {:continue, next}, next_binding} =
                 Live.advance(
                   binding,
                   pending,
                   event,
                   %{request_id: request["id"], lexical_path: path},
                   @timeout
                 )

        read = read_root(next)
        assert_mark(next_binding, read, "call-B", true)
        {:ok, {next_binding, next, read}}
      end

      assert {:ok, later} = run_closed(root, "serial.json", {:read_locked, callback})
      {binding, next, read} = later.value
      assert later === read_summary(@text, {binding, next, read})
      assert_mark(binding, read, "call-B", true)
      {_final, binding} = complete(binding, next)
      assert Live.release(binding, @timeout) == :ok
      assert File.read!(path) === @text
      assert File.ls!(root) == ["serial.json"]
    after
      :erlang.trace_pattern({Access, :acquire, 2}, false, [:local])
      send(callback_pid, {gate, :finish_read})
    end
  end

  defp remember_existing(owner, path, key) do
    {root, heap} = item()
    {binding, pending, request} = pending(owner, "state.set record", [root], heap, key)
    assert request["text"] == @text
    # Semantic ACK seeds only the internal cache of the already-existing file.
    event = %{"id" => request["id"], "kind" => "state_set", "result" => "ok"}

    assert {:ok, {:continue, next}, binding} =
             Live.advance(
               binding,
               pending,
               event,
               %{request_id: request["id"], lexical_path: path},
               @timeout
             )

    {_final, binding} = complete(binding, next)
    assert Live.release(binding, @timeout) == :ok
  end

  defp pending(owner, pipeline, items, heap, key \\ nil) do
    assert {:ok, program} = Pipeline.parse(pipeline)

    assert {:ok, machine} =
             Machine.new(program, %{"kind" => "iterator_items", "items" => items}, heap, %{
               "render_output" => false
             })

    # The test is the original driver/lease owner. Local callbacks merely use
    # the captured volatile binding and return its successor to that driver.
    assert {:ok, binding} = Live.open(owner, machine, @timeout)

    binding =
      if key do
        assert [root] = items

        assert {:ok, marked} =
                 Owner.publish(
                   binding,
                   Value.heap_delta(heap, heap),
                   [{:mark_item, root, Value.key_string(key), false}],
                   @timeout
                 )

        marked
      else
        binding
      end

    {binding, request, pending} = request(binding, machine)
    {binding, pending, request}
  end

  defp request(binding, machine, remaining \\ 4_000)
  defp request(_binding, _machine, 0), do: flunk("ordinary request transition bound exceeded")

  defp request(binding, machine, remaining) do
    assert {:ok, transition, next_binding} = Live.advance(binding, machine, nil, nil, @timeout)

    case transition do
      {:continue, next} -> request(next_binding, next, remaining - 1)
      {:request, request, pending} -> {next_binding, request, pending}
      other -> flunk("unexpected ordinary request transition: #{inspect(other)}")
    end
  end

  defp complete(binding, machine, remaining \\ 4_000)
  defp complete(_binding, _machine, 0), do: flunk("ordinary completion transition bound exceeded")

  defp complete(binding, machine, remaining) do
    assert {:ok, transition, next_binding} = Live.advance(binding, machine, nil, nil, @timeout)

    case transition do
      {:continue, next} -> complete(next_binding, next, remaining - 1)
      {:complete, _result, final} -> {final, next_binding}
      other -> flunk("unexpected ordinary completion transition: #{inspect(other)}")
    end
  end

  defp read_root(machine) do
    frame = List.last(machine["frames"])
    assert [root] = machine["streams"][frame["output"]]["items"]
    root
  end

  defp item do
    assert {:ok, root, heap} = Value.decode_json(@text)
    {root, heap}
  end

  defp assert_mark(binding, root, key, replayed) do
    assert Owner.provenance_of(binding, root, @timeout) ==
             {:ok, %{cache_key: Value.key_string(key), replayed: replayed}}
  end

  defp run_closed(root, path, operation) do
    assert {:ok, ticket} =
             Local.start_state_operation(root, path,
               deadline: System.monotonic_time(:millisecond) + 10_000,
               owner_pid: self()
             )

    guardian = Local.state_operation_owner(ticket)
    assert is_pid(guardian)
    assert Process.alive?(guardian)
    monitor = Process.monitor(guardian)
    assert {:ok, %{phase: :dormant, evidence: nil}} = Local.state_operation_status(ticket)

    try do
      result = Local.run_state_operation(ticket, operation)
      assert {:ok, _summary} = result
      assert Process.alive?(guardian)
      assert {:ok, %{phase: :settled}} = Local.state_operation_status(ticket)
      result
    after
      assert :ok = Local.close_state_operation(ticket)
      assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 1_000
      refute Process.alive?(guardian)
    end
  end

  defp read_summary(bytes, value) do
    %{
      before: %{exists: true, bytes: bytes},
      value: value,
      publication: :not_applicable,
      file_sync: :not_applicable,
      directory_sync: :not_applicable,
      cleanup_confirmed: true
    }
  end

  defp published do
    %{
      before: :not_captured,
      value: nil,
      publication: :published,
      file_sync: :confirmed,
      directory_sync: :confirmed,
      cleanup_confirmed: true
    }
  end
end
