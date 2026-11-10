defmodule Synapsis.Agent.Tools.SandboxNativeFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolCatalog}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Sandbox.Bridge

  @moduletag :tmp_dir

  # These are test-only native backends. No production Sandbox descriptor exists.
  defmodule SandboxBackend do
    def execute(operation) do
      context = operation.backend_context
      conversation = context.resource_owner_pid
      dispatch = context.nested_dispatch
      owner = context.owner

      adapter = fn request ->
        result = dispatch.(request)
        {:ok, record} = EphemeralStore.load(context.table, operation.run_id)
        send(owner, {:nested_reply, result, record.run})

        case result do
          {:ok, result} -> {:ok, JSON.decode!(JSON.encode!(result))}
          {:error, _} -> {:error, %{code: -32_000, message: "Native call failed"}}
        end
      end

      {:ok, bridge} =
        Bridge.start_link(
          command: System.find_executable("python3"),
          args: ["-u", context.script],
          task_supervisor: context.tasks,
          owner: self(),
          nested_dispatch: adapter,
          invocation_binding:
            Map.merge(
              Map.take(operation, [:run_id, :incarnation, :catalog_revision, :invocation_id]),
              %{session_id: context.session_id}
            ),
          abort: fn _ -> Conversation.cancel(conversation) end,
          reverse_timeout_ms: context.reverse_timeout_ms
        )

      send(owner, {:bridge_started, bridge, self(), :sys.get_state(bridge).port})

      try do
        case Bridge.eval(bridge, "ordinary nested file write", 2_000) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:ok, %{is_error: true, content: "Sandbox stopped"}}
        end
      after
        if Process.alive?(bridge), do: GenServer.stop(bridge)
      end
    end
  end

  defmodule FileBackend do
    def execute(operation) do
      context = operation.backend_context
      {:ok, record} = EphemeralStore.load(context.table, operation.run_id)
      send(context.owner, {:before_file_effect, self(), operation, record.run})

      if context.pause do
        receive do
          :finish -> :ok
        end
      end

      path = Path.join(context.root, operation.arguments["path"])
      File.write!(path, operation.arguments["content"])

      {:ok,
       %{
         content: [%{type: "text", text: "written"}, %{type: "text", text: "verified"}],
         structured_content: %{
           path: path,
           bytes: byte_size(operation.arguments["content"]),
           order: [2, 1]
         },
         is_error: false
       }}
    end
  end

  test "genuine nested dispatcher commits intent before file effect and completion before reply",
       ctx do
    native = start_native!(ctx, false)
    prompt = Task.async(fn -> Conversation.prompt(native.pid, "Write ordinary file") end)
    assert_receive {:bridge_started, bridge, _effect, _port}, 1_000
    assert_receive {:before_file_effect, _nested, operation, before}, 1_000

    assert get_in(before.execution_intents, [
             "tool:#{operation.invocation_id}",
             :operation,
             :tool_name
           ]) == "file_write"

    refute Map.has_key?(before.tool_results, operation.invocation_id)
    assert_receive {:nested_reply, {:ok, result}, completed}, 1_000
    assert completed.tool_results[operation.invocation_id] == result
    assert completed.expected_revision > before.expected_revision
    assert result.content == [%{type: "text", text: "written"}, %{type: "text", text: "verified"}]
    assert result.structured_content.order == [2, 1]
    assert result.is_error == false
    assert File.read!(Path.join(ctx.tmp_dir, "ordinary.txt")) == "hello native\n"
    assert {:ok, _} = Task.await(prompt, 3_000)
    status = await_status(native.pid, fn s -> s.phase == :terminal end)
    assert status.run.state == :completed, inspect(status.error)

    [outer] =
      for {_id, value} <- status.run.tool_results,
          is_map(value) and Map.has_key?(value, "nested"),
          do: value

    assert outer["nested"]["result"] == JSON.decode!(JSON.encode!(result))
    refute Process.alive?(bridge)
  end

  test "reverse timeout settles native cancellation and stops bridge Port and waiter", ctx do
    native = start_native!(ctx, true)
    prompt = Task.async(fn -> Conversation.prompt(native.pid, "Start ordinary operation") end)
    assert_receive {:bridge_started, bridge, effect, port}, 1_000
    assert_receive {:before_file_effect, nested, _operation, _record}, 1_000
    [{_, pending}] = Map.to_list(:sys.get_state(bridge).pending_tools)
    waiter = pending.task.pid
    refs = for pid <- [bridge, effect, nested, waiter], do: {pid, Process.monitor(pid)}
    _ = Task.await(prompt, 3_000)
    status = await_status(native.pid, fn s -> s.phase == :terminal end)
    # An interrupted write retains native uncertainty even though all live work
    # has settled. A cancel acknowledgement never upgrades it to success.
    assert status.run.state == :unknown_outcome
    for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 1_000)
    assert Port.info(port) == nil
    refute File.exists?(Path.join(ctx.tmp_dir, "ordinary.txt"))
  end

  defp start_native!(ctx, pause) do
    tasks = start_supervised!(Task.Supervisor)
    script = Path.join(ctx.tmp_dir, "native_sandbox.py")

    File.write!(script, """
    import json, sys, time
    request = json.loads(sys.stdin.readline())
    print(json.dumps({"jsonrpc":"2.0","id":"ordinary-write","method":"file_write","params":{"path":"ordinary.txt","content":"hello native\\n"}}), flush=True)
    response = json.loads(sys.stdin.readline())
    print(json.dumps({"id":request["id"],"result":{"nested":response}}), flush=True)
    time.sleep(2)
    """)

    run_id = Ecto.UUID.generate()

    options =
      Proof.options(run_id, fn request ->
        if Enum.any?(request.messages, &(Map.get(&1, :role) == :tool)) do
          [Proof.completed("Written")]
        else
          [Proof.call("sandbox_test", %{}), Proof.completed("Writing")]
        end
      end)

    context = %{
      owner: self(),
      tasks: tasks,
      table: options[:context],
      script: script,
      root: ctx.tmp_dir,
      session_id: Ecto.UUID.generate(),
      pause: pause,
      reverse_timeout_ms: if(pause, do: 300, else: 1_500)
    }

    descriptors = [
      %{
        tool_name: "sandbox_test",
        tool_revision: 1,
        backend: SandboxBackend,
        backend_context: context,
        schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        safety: %{read_only: false, retry_safe: false, parallel_safe: false}
      },
      %{
        tool_name: "file_write",
        tool_revision: 1,
        backend: FileBackend,
        backend_context: context,
        schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}, "content" => %{"type" => "string"}},
          "required" => ["path", "content"],
          "additionalProperties" => false
        },
        safety: %{read_only: false, retry_safe: false, parallel_safe: false}
      }
    ]

    authority = %{
      caller: "sandbox-functional-host",
      run_id: run_id,
      grants: ["sandbox_test", "file_write"],
      tool_revision: 1
    }

    {:ok, catalog} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority)

    pid =
      start_supervised!(
        {Conversation,
         Keyword.merge(options,
           registry: catalog.registry,
           tools: catalog.tools,
           authority: catalog.authority,
           schema_admission: :strict,
           effect_timeout: 2_500,
           work: 10
         )}
      )

    %{pid: pid}
  end

  defp await_status(pid, condition, attempts \\ 100) do
    status = Conversation.status(pid)

    cond do
      condition.(status) ->
        status

      attempts == 0 ->
        flunk("native conversation did not settle: #{inspect(status.phase)}")

      true ->
        Process.sleep(10)
        await_status(pid, condition, attempts - 1)
    end
  end
end
