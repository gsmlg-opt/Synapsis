defmodule Synapsis.MCP.ToolCallContractTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.{Error, Response}
  alias Synapsis.MCP.Transport
  alias Synapsis.MCPConfig

  setup do
    owner = self()
    bypass = Bypass.open()
    Bypass.stub(bypass, "GET", "/mcp", &Plug.Conn.resp(&1, 200, ""))
    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 200, ""))

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request do
        %{"method" => "initialize", "id" => id} ->
          reply(conn, id, %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "owned-calls", "version" => "1"}
          })

        %{"method" => "tools/call", "id" => id, "params" => %{"name" => "pending"}} ->
          send(owner, {:pending_call, id})
          Plug.Conn.resp(conn, 202, "")

        %{"method" => "tools/call", "id" => id} ->
          reply(conn, id, %{"content" => [%{"type" => "text", "text" => "completed"}]})

        %{"method" => "notifications/cancelled", "params" => params} ->
          send(owner, {:cancelled_call, params})
          Plug.Conn.resp(conn, 202, "")

        _notification ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    config = %MCPConfig{transport: "streamable_http", url: "http://localhost:#{bypass.port}/mcp"}
    client = __MODULE__.Client

    start_supervised!(
      {Client,
       name: client,
       transport: Transport.build(config),
       protocol_version: Transport.protocol_version(config),
       client_info: %{"name" => "synapsis-contract", "version" => "1"},
       capabilities: %{}}
    )

    assert :ok = Client.await_ready(client, timeout: 2_000)
    %{client: client, tasks: start_supervised!(Task.Supervisor)}
  end

  test "cancels only its owned call and preserves sibling and synchronous calls", ctx do
    assert {:ok, pending} = Client.start_tool_call(ctx.client, "pending", %{}, timeout: 5_000)
    assert_receive {:pending_call, id}, 2_000
    assert {:ok, sibling} = Client.start_tool_call(ctx.client, "echo", %{}, timeout: 5_000)

    assert {:ok, %{local: :cancelled, notification_delivery: :accepted, remote: :unknown}} =
             Client.cancel_tool_call(pending, "consumer_cancel", notification_timeout: 1_000)

    assert_receive {:cancelled_call, %{"requestId" => ^id, "reason" => "consumer_cancel"}}, 2_000
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(pending, 2_000)
    assert {:ok, response} = Client.await_tool_call(sibling, 2_000)
    assert_completed(response)
    assert {:ok, response} = Client.call_tool(ctx.client, "echo", %{}, timeout: 2_000)
    assert_completed(response)
  end

  test "foreign owners cannot await or cancel another caller's operation", ctx do
    assert {:ok, handle} = Client.start_tool_call(ctx.client, "pending", %{}, timeout: 5_000)
    assert_receive {:pending_call, id}, 2_000

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        {Client.await_tool_call(handle, 100), Client.cancel_tool_call(handle)}
      end)

    assert {:ok,
            {{:error, %Error{reason: :request_owner_mismatch}},
             {:error, %Error{reason: :request_owner_mismatch}}}} = Task.yield(task, 2_000)

    refute_receive {:cancelled_call, _}
    assert {:ok, %{local: :cancelled}} = Client.cancel_tool_call(handle)
    assert_receive {:cancelled_call, %{"requestId" => ^id}}, 2_000
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(handle, 2_000)
  end

  test "owner death cancels its remote request without terminating the shared client", ctx do
    owner = self()

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        {:ok, handle} = Client.start_tool_call(ctx.client, "pending", %{}, timeout: 5_000)
        send(owner, :owner_registered)
        Client.await_tool_call(handle, 5_000)
      end)

    assert_receive :owner_registered, 2_000
    assert_receive {:pending_call, id}, 2_000
    assert {:ok, sibling} = Client.start_tool_call(ctx.client, "echo", %{}, timeout: 5_000)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:cancelled_call, %{"requestId" => ^id, "reason" => "owner_down"}}, 2_000
    assert {:ok, response} = Client.await_tool_call(sibling, 2_000)
    assert_completed(response)
    assert Process.alive?(Process.whereis(ctx.client))
  end

  defp assert_completed(response) do
    assert %{"content" => [%{"type" => "text", "text" => "completed"}]} =
             Response.unwrap(response)
  end

  defp reply(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end
end
