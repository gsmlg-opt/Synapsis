defmodule Synapsis.MCP.NativeSnapshotTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  setup do
    fixture = Gaoxy.Test.open()
    owner = self()
    state = start_supervised!({Agent, fn -> %{description: "original", is_error: false} end})

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      current = Agent.get(state, & &1)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "native-snapshot", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "echo",
                  "description" => current.description,
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{"text" => %{"type" => "string"}},
                    "required" => ["text"],
                    "additionalProperties" => false
                  },
                  "annotations" => %{"readOnlyHint" => true}
                }
              ]
            }

          "tools/call" ->
            send(owner, {:native_mcp_call, request["params"]})

            if request["params"]["arguments"]["text"] == "pending" do
              send(owner, {:native_mcp_pending, request["id"]})
              :pending
            else
              %{
                "content" => [
                  %{"type" => "text", "text" => request["params"]["arguments"]["text"]}
                ],
                "structuredContent" => %{"retained" => true},
                "isError" => current.is_error
              }
            end

          "notifications/cancelled" ->
            send(owner, {:native_mcp_cancelled, request["params"]})
            %{}

          _ ->
            %{}
        end

      if Map.has_key?(request, "id") and result != :pending do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)

    {:ok, config} =
      MCPConfigs.create(%{
        name: "native-snapshot-#{System.unique_integer([:positive])}",
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      })

    pid = start_supervised!(Supervisor.child_spec({Server, config}, restart: :temporary))
    assert :ok = Server.await_ready(pid)
    on_exit(fn -> MCPConfigs.delete(config) end)
    %{pid: pid, config: config, state: state}
  end

  test "snapshot uses stable source identity and retains rich MCP result", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)
    assert snapshot.source_id == ctx.config.id
    assert snapshot.server_pid == ctx.pid
    assert [%{raw_name: "echo", permission_level: :write}] = snapshot.tools
    assert {:ok, result} = Server.runtime_call(snapshot, "echo", %{"text" => "rich"}, 2_000)
    assert result["structuredContent"] == %{"retained" => true}
    assert result["content"] == [%{"type" => "text", "text" => "rich"}]
    assert result["isError"] == false
    assert_receive {:native_mcp_call, %{"name" => "echo"}}
  end

  test "same-name refreshed schema invalidates the previous snapshot before dispatch", ctx do
    assert {:ok, old} = Server.runtime_snapshot(ctx.pid)
    Agent.update(ctx.state, &%{&1 | description: "replacement"})
    assert :ok = Server.refresh(ctx.pid)

    assert {:rejected, :stale_snapshot} =
             Server.runtime_call(old, "echo", %{"text" => "no"}, 2_000)

    refute_receive {:native_mcp_call, _}
    assert {:ok, fresh} = Server.runtime_snapshot(ctx.pid)
    refute fresh.generation == old.generation
    assert {:ok, _} = Server.runtime_call(fresh, "echo", %{"text" => "fresh"}, 2_000)
  end

  test "revoked source and absent tools are rejected before dispatch", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)
    assert {:rejected, :tool_unavailable} = Server.runtime_call(snapshot, "foreign", %{}, 2_000)
    assert {:ok, _} = MCPConfigs.update(ctx.config, %{enabled: false})
    assert {:error, :mcp_unavailable} = Server.runtime_snapshot(ctx.pid)

    assert {:rejected, :stale_snapshot} =
             Server.runtime_call(snapshot, "echo", %{"text" => "no"}, 2_000)

    refute_receive {:native_mcp_call, _}
  end

  test "remote isError stays a completed response for native settlement", ctx do
    Agent.update(ctx.state, &%{&1 | is_error: true})
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)

    assert {:ok, %{"isError" => true}} =
             Server.runtime_call(snapshot, "echo", %{"text" => "remote failure"}, 2_000)
  end

  test "source revocation between lookup and admission rejects without remote dispatch", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)

    :erlang.trace_pattern({Server, :lookup_source_tool, 4}, [{:_, [], [{:return_trace}]}], [
      :local
    ])

    on_exit(fn -> :erlang.trace_pattern({Server, :lookup_source_tool, 4}, false, [:local]) end)
    owner = self()

    task =
      Synapsis.Config.Store.with_write_lock(fn ->
        task =
          Task.async(fn ->
            receive do: (:go -> Server.runtime_call(snapshot, "echo", %{"text" => "no"}, 2_000))
          end)

        :erlang.trace(task.pid, true, [:call, {:tracer, owner}])
        send(task.pid, :go)
        pid = task.pid

        assert_receive {:trace, ^pid, :return_from, {Server, :lookup_source_tool, 4}, {:ok, _}},
                       1_000

        assert {:ok, _} = MCPConfigs.update(ctx.config, %{enabled: false})
        task
      end)

    assert {:rejected, :stale_snapshot} = Task.await(task, 3_000)
    refute_receive {:native_mcp_call, _}
  end

  test "same-name publication between lookup and admission invalidates the ticket", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)

    :erlang.trace_pattern({Server, :lookup_source_tool, 4}, [{:_, [], [{:return_trace}]}], [
      :local
    ])

    on_exit(fn -> :erlang.trace_pattern({Server, :lookup_source_tool, 4}, false, [:local]) end)

    task =
      Synapsis.Config.Store.with_write_lock(fn ->
        task =
          Task.async(fn ->
            receive do: (:go -> Server.runtime_call(snapshot, "echo", %{"text" => "no"}, 2_000))
          end)

        :erlang.trace(task.pid, true, [:call, {:tracer, self()}])
        send(task.pid, :go)
        pid = task.pid

        assert_receive {:trace, ^pid, :return_from, {Server, :lookup_source_tool, 4}, {:ok, _}},
                       1_000

        :erlang.suspend_process(task.pid)
        task
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    Agent.update(ctx.state, &%{&1 | description: "changed while caller paused"})
    assert :ok = Server.refresh(ctx.pid)
    :erlang.resume_process(task.pid)
    assert {:rejected, :stale_snapshot} = Task.await(task, 3_000)
    refute_receive {:native_mcp_call, _}
  end

  test "admission contention cannot dispatch after the original timeout", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)

    Synapsis.Config.Store.with_write_lock(fn ->
      task = Task.async(fn -> Server.runtime_call(snapshot, "echo", %{"text" => "no"}, 50) end)
      assert {:rejected, :timeout} = Task.await(task, 1_000)
    end)

    refute_receive {:native_mcp_call, _}
  end

  test "snapshot metadata and changed transport cannot select a different call", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)
    [tool] = snapshot.tools
    changed = %{snapshot | tools: [%{tool | permission_level: :read}]}

    assert {:rejected, :stale_snapshot} =
             Server.runtime_call(changed, "echo", %{"text" => "no"}, 1_000)

    assert {:ok, _} = MCPConfigs.update(ctx.config, %{url: "http://127.0.0.1:1/mcp"})

    assert {:rejected, :stale_snapshot} =
             Server.runtime_call(snapshot, "echo", %{"text" => "no"}, 1_000)

    refute_receive {:native_mcp_call, _}
  end

  test "timeout cancels the caller-owned request and leaves sibling calls usable", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)
    assert {:error, :timeout} = Server.runtime_call(snapshot, "echo", %{"text" => "pending"}, 100)
    assert_receive {:native_mcp_pending, id}

    assert_receive {:native_mcp_cancelled, %{"requestId" => ^id, "reason" => "tool_timeout"}},
                   2_000

    assert {:ok, _} = Server.runtime_call(snapshot, "echo", %{"text" => "sibling"}, 2_000)
  end

  test "effect owner death cancels its request without stopping the shared server", ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)

    task =
      Task.async(fn -> Server.runtime_call(snapshot, "echo", %{"text" => "pending"}, 5_000) end)

    assert_receive {:native_mcp_pending, id}, 2_000
    Task.shutdown(task, :brutal_kill)
    assert_receive {:native_mcp_cancelled, %{"requestId" => ^id, "reason" => "owner_down"}}, 2_000
    assert Process.alive?(ctx.pid)
    assert {:ok, _} = Server.runtime_call(snapshot, "echo", %{"text" => "sibling"}, 2_000)
  end

  test "server death between lookup and admission rejects while client teardown is delayed",
       ctx do
    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)
    state = :sys.get_state(ctx.pid)
    client = GenServer.whereis(state.client)

    :erlang.trace_pattern({Server, :lookup_source_tool, 4}, [{:_, [], [{:return_trace}]}], [
      :local
    ])

    on_exit(fn -> :erlang.trace_pattern({Server, :lookup_source_tool, 4}, false, [:local]) end)

    task =
      Synapsis.Config.Store.with_write_lock(fn ->
        task =
          Task.async(fn ->
            receive do: (:go -> Server.runtime_call(snapshot, "echo", %{"text" => "no"}, 2_000))
          end)

        :erlang.trace(task.pid, true, [:call, {:tracer, self()}])
        send(task.pid, :go)
        pid = task.pid

        assert_receive {:trace, ^pid, :return_from, {Server, :lookup_source_tool, 4}, {:ok, _}},
                       1_000

        :erlang.suspend_process(task.pid)
        task
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)

    true = :erlang.suspend_process(state.supervisor)

    try do
      ref = Process.monitor(ctx.pid)
      Process.exit(ctx.pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      assert Process.alive?(client)
      :erlang.resume_process(task.pid)
      assert {:rejected, :stale_snapshot} = Task.await(task, 3_000)
      refute_receive {:native_mcp_call, _}
    after
      try do
        :erlang.resume_process(state.supervisor)
      catch
        :error, :badarg -> :ok
      end
    end
  end
end
