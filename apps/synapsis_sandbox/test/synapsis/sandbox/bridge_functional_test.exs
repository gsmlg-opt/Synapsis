defmodule Synapsis.Sandbox.BridgeFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Sandbox.Bridge

  @moduletag :tmp_dir

  test "reverse function input uses the injected host dispatcher and preserves its result", ctx do
    owner = self()

    result = %{
      "content" => [
        %{"type" => "text", "text" => "first"},
        %{"type" => "text", "text" => "second"}
      ],
      "structured_content" => %{"items" => [2, 1]},
      "is_error" => true,
      "extra" => %{"value" => "kept"}
    }

    script =
      script!(ctx.tmp_dir, """
      request = json.loads(sys.stdin.readline())
      print(json.dumps({"jsonrpc":"2.0","id":"nested-1","method":"file_write","params":{"path":"ordinary.txt","content":"hello"}}), flush=True)
      response = json.loads(sys.stdin.readline())
      print(json.dumps({"id":request["id"],"result":response}), flush=True)
      time.sleep(2)
      """)

    pid =
      bridge!(script,
        nested_dispatch: fn request ->
          send(owner, {:dispatch, request})
          {:ok, result}
        end
      )

    assert {:ok, response} = Bridge.eval(pid, "ordinary", 2_000)

    assert_receive {:dispatch,
                    %{
                      tool_name: "file_write",
                      arguments: %{"path" => "ordinary.txt", "content" => "hello"}
                    }}

    assert response == %{"jsonrpc" => "2.0", "id" => "nested-1", "result" => result}
    refute_receive {:dispatch, _}
  end

  test "split responses and console output preserve host-only framing", ctx do
    script =
      script!(ctx.tmp_dir, """
      request = json.loads(sys.stdin.readline())
      response = json.dumps({"id":request["id"],"result":{"value":"split"}})
      sys.stdout.write(response[:10]); sys.stdout.flush()
      time.sleep(0.03)
      print(response[10:] + "\\nconsole noise", flush=True)
      time.sleep(1)
      """)

    pid = bridge!(script, output_pid: self())
    assert {:ok, %{"value" => "split"}} = Bridge.eval(pid, "ordinary", 1_000)
    assert_receive {:sandbox_output, "console noise"}
  end

  test "eval completion waits for reverse settlement and concurrent reverse calls report busy",
       ctx do
    owner = self()

    script =
      script!(ctx.tmp_dir, """
      request = json.loads(sys.stdin.readline())
      print(json.dumps({"id":"one","method":"ordinary","params":{}}), flush=True)
      print(json.dumps({"id":"two","method":"ordinary","params":{}}), flush=True)
      busy = json.loads(sys.stdin.readline())
      print(json.dumps({"id":request["id"],"result":{"done":True,"busy":busy}}), flush=True)
      time.sleep(2)
      """)

    pid =
      bridge!(script,
        nested_dispatch: fn _ ->
          send(owner, {:waiter, self()})

          receive do
            :finish -> {:ok, %{"done" => true}}
          end
        end
      )

    eval = Task.async(fn -> Bridge.eval(pid, "ordinary", 1_500) end)
    assert_receive {:waiter, waiter}
    assert Task.yield(eval, 50) == nil
    send(waiter, :finish)

    assert {:ok,
            %{
              "done" => true,
              "busy" => %{
                "id" => "two",
                "error" => %{"code" => -32_002, "message" => "Tool dispatch busy"}
              }
            }} = Task.await(eval)

    refute_receive {:waiter, _}
    assert {:error, :closed} = Bridge.eval(pid, "again", 100)
  end

  test "host public errors produce one JSON-RPC error", ctx do
    script =
      script!(ctx.tmp_dir, """
      request = json.loads(sys.stdin.readline())
      print(json.dumps({"id":"one","method":"ordinary","params":{}}), flush=True)
      response = json.loads(sys.stdin.readline())
      print(json.dumps({"id":request["id"],"result":response}), flush=True)
      time.sleep(1)
      """)

    pid =
      bridge!(script,
        nested_dispatch: fn _ -> {:error, %{code: -32_010, message: "Ordinary failure"}} end
      )

    assert {:ok,
            %{"error" => %{"code" => -32_010, "message" => "Ordinary failure"}, "id" => "one"}} =
             Bridge.eval(pid, "ordinary", 1_000)
  end

  test "eval timeout stops waiter and Port and invokes bounded native abort", ctx do
    assert_lifecycle(ctx, :timeout, :eval_timeout)
  end

  test "reverse timeout stops waiter and Port and invokes bounded native abort", ctx do
    assert_lifecycle(ctx, :reverse_timeout, :reverse_timeout)
  end

  test "Port exit stops waiter and Port and invokes bounded native abort", ctx do
    assert_lifecycle(ctx, :port_exit, {:sandbox_exited, 3})
  end

  test "owner loss stops waiter and Port and invokes bounded native abort", ctx do
    assert_lifecycle(ctx, :owner_loss, :owner_down)
  end

  defp assert_lifecycle(ctx, action, expected) do
    owner = self()

    effect_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(effect_owner), do: send(effect_owner, :stop) end)

    script =
      script!(ctx.tmp_dir, """
      request = json.loads(sys.stdin.readline())
      print(json.dumps({"id":"one","method":"ordinary","params":{}}), flush=True)
      #{if action == :port_exit, do: "time.sleep(0.1); sys.exit(3)", else: "time.sleep(5)"}
      """)

    pid =
      bridge!(script,
        owner: effect_owner,
        reverse_timeout_ms: if(action == :reverse_timeout, do: 100, else: 2_000),
        nested_dispatch: fn _ ->
          send(owner, {:waiter, self()})

          receive do
            :finish -> {:ok, %{}}
          end
        end,
        abort: fn reason ->
          send(owner, {:aborting, self(), reason})

          receive do
            :finish_abort -> :ok
          end
        end,
        abort_timeout_ms: 50
      )

    bridge_ref = Process.monitor(pid)
    port = :sys.get_state(pid).port

    caller =
      Task.async(fn ->
        Bridge.eval(pid, "ordinary", if(action == :timeout, do: 100, else: 2_000))
      end)

    assert_receive {:waiter, waiter}
    waiter_ref = Process.monitor(waiter)
    if action == :owner_loss, do: send(effect_owner, :stop)
    assert {:error, failure} = Task.await(caller)
    assert failure == if(action == :timeout, do: :timeout, else: expected)
    assert_receive {:aborting, abort_task, ^expected}, 1_000
    abort_ref = Process.monitor(abort_task)
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, _}
    assert_receive {:DOWN, ^abort_ref, :process, ^abort_task, _}
    assert_receive {:DOWN, ^bridge_ref, :process, ^pid, ^expected}
    assert Port.info(port) == nil
  end

  test "callback exit and unexpected result stop stably with bounded cleanup", ctx do
    for callback <- [fn _ -> exit(:ordinary_failure) end, fn _ -> :unexpected end] do
      script =
        script!(ctx.tmp_dir, """
        request = json.loads(sys.stdin.readline())
        print(json.dumps({"id":"one","method":"ordinary","params":{}}), flush=True)
        time.sleep(5)
        """)

      pid = bridge!(script, nested_dispatch: callback)
      ref = Process.monitor(pid)
      assert {:error, reason} = Bridge.eval(pid, "ordinary", 1_000)
      assert reason in [:reverse_task_failed, :reverse_protocol_failure]
      assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
    end
  end

  defp bridge!(script, opts) do
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())

    {:ok, pid} =
      Bridge.start_link(
        Keyword.merge(
          [
            command: System.find_executable("python3"),
            args: ["-u", script],
            task_supervisor: supervisor,
            owner: self(),
            invocation_binding: %{
              session_id: Ecto.UUID.generate(),
              run_id: "run",
              incarnation: 1,
              catalog_revision: 1,
              invocation_id: "outer"
            },
            abort: fn _reason -> :ok end
          ],
          opts
        )
      )

    Process.unlink(pid)
    on_exit(fn -> stop_bridge(pid) end)
    pid
  end

  defp stop_bridge(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp script!(root, body) do
    path = Path.join(root, "sandbox.py")
    File.write!(path, "import json, sys, time\n" <> body)
    path
  end
end
