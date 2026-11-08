defmodule Synapsis.Agent.Tools.MCPTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Budget,
    EphemeralStore,
    Error,
    Execution,
    ToolCatalog,
    ToolEffects
  }

  alias Synapsis.Agent.Tools.MCP
  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  @run "root / nested:α"

  setup do
    fixture = Gaoxy.Test.open()
    owner = self()
    state = start_supervised!({Agent, fn -> %{description: "original", response: :rich} end})

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
              "serverInfo" => %{"name" => "native-tools", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "echo.raw",
                  "description" => current.description,
                  "inputSchema" => schema(),
                  "annotations" => %{"readOnlyHint" => true}
                }
              ]
            }

          "tools/call" ->
            send(owner, {:mcp_native_called, request["params"]})

            case current.response do
              :pending ->
                send(owner, {:mcp_native_pending, request["id"]})
                :pending

              :transport_error ->
                :transport_error

              :rich ->
                rich_result()

              result ->
                result
            end

          "notifications/cancelled" ->
            send(owner, {:mcp_native_cancelled, request["params"]})
            %{}

          _ ->
            %{}
        end

      cond do
        result == :transport_error ->
          Plug.Conn.resp(conn, 503, "private transport details")

        Map.has_key?(request, "id") and result != :pending ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
          )

        true ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    {:ok, config} =
      MCPConfigs.create(%{
        name: "native-tools-#{System.unique_integer([:positive])}",
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      })

    pid = start_supervised!(Supervisor.child_spec({Server, config}, restart: :temporary))
    assert :ok = Server.await_ready(pid)
    assert {:ok, source} = Server.runtime_snapshot(pid)
    on_exit(fn -> MCPConfigs.delete(config) end)
    context = %{source: source, run_id: @run, incarnation: 1, catalog_revision: 1}

    %{
      pid: pid,
      config: config,
      state: state,
      context: context,
      name: "mcp::#{source.source_id}::echo.raw"
    }
  end

  test "strict admission retains original schema, exact source identity and conservative safety",
       ctx do
    assert {:ok, [descriptor] = descriptors} = MCP.descriptors(ctx.context)
    assert descriptor.tool_name == ctx.name
    assert descriptor.tool_revision === ctx.context.source.generation
    assert descriptor.schema === schema()
    assert descriptor.backend == MCP
    assert descriptor.backend_context === ctx.context
    assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert {:ok, :write} = MCP.permission_level(ctx.context, ctx.name)

    assert {:ok, %{accepted: [name], tools: [%{parameters: parameters}]}} =
             ToolCatalog.admit_batch(descriptors, authority: authority(ctx))

    assert name == ctx.name
    assert parameters === schema()

    for changed <- [
          %{authority(ctx) | grants: ["*"]},
          %{authority(ctx) | grants: []},
          %{authority(ctx) | tool_revisions: %{ctx.name => ctx.context.source.generation + 1}}
        ] do
      assert {:error, %Error{}} = ToolCatalog.admit_batch(descriptors, authority: changed)
    end

    assert {:ok, %{action: "mcp.tool.call", resource: resource}} =
             MCP.classify(ctx.context, operation(ctx))

    assert resource == "mcp:source:#{ctx.config.id}:tool:echo.raw"
    refute_receive {:mcp_native_called, _}
  end

  test "invalid scope, forged source metadata and model source selectors are rejected", ctx do
    for context <- [
          nil,
          Map.put(ctx.context, :agent_id, "foreign"),
          %{ctx.context | run_id: " "},
          %{ctx.context | incarnation: 0},
          %{ctx.context | catalog_revision: 1.0},
          put_in(ctx.context, [:source, :source_id], Ecto.UUID.generate()),
          put_in(ctx.context, [:source, :tools, Access.at(0), :permission_level], :read)
        ] do
      assert {:error, _} = MCP.descriptors(context)
    end

    for {field, value} <- [
          run_id: "foreign",
          incarnation: 2,
          catalog_revision: 2,
          tool_revision: ctx.context.source.generation + 1
        ] do
      op = Map.put(operation(ctx), field, value)
      assert {:error, _} = MCP.classify(ctx.context, op)
      assert {:rejected, proof} = MCP.execute(op)
      assert {:ok, %{is_error: true}} = ToolEffects.validate_rejection(proof, op)
    end

    assert {:error, _} = MCP.classify(ctx.context, %{operation(ctx) | incarnation: 1.0})

    for arguments <- [
          %{},
          %{"text" => "q", "source" => "foreign"},
          %{"text" => "q", "root" => "/"},
          %{"text" => 1}
        ] do
      op = %{operation(ctx) | arguments: arguments}
      assert {:rejected, proof} = MCP.execute(op)
      assert {:ok, %{is_error: true}} = ToolEffects.validate_rejection(proof, op)
    end

    tampered = put_in(operation(ctx), [:backend_context, :source, :generation], 999)
    assert {:error, _} = MCP.classify(ctx.context, tampered)
    refute_receive {:mcp_native_called, _}
  end

  test "source refresh and revocation invalidate both classification and effect admission", ctx do
    assert {:ok, _} = MCP.classify(ctx.context, operation(ctx))
    Agent.update(ctx.state, &%{&1 | description: "changed schema binding"})
    assert :ok = Server.refresh(ctx.pid)
    assert {:error, _} = MCP.classify(ctx.context, operation(ctx))
    assert {:rejected, proof} = MCP.execute(operation(ctx))
    assert {:ok, %{is_error: true}} = ToolEffects.validate_rejection(proof, operation(ctx))

    {:ok, source} = Server.runtime_snapshot(ctx.pid)
    fresh = put_in(ctx, [:context, :source], source)
    assert {:ok, _} = MCP.classify(fresh.context, operation(fresh))
    assert {:ok, _} = MCPConfigs.update(ctx.config, %{enabled: false})
    assert {:error, _} = MCP.descriptors(fresh.context)
    assert {:rejected, proof} = MCP.execute(operation(fresh))
    assert {:ok, %{is_error: true}} = ToolEffects.validate_rejection(proof, operation(fresh))
    refute_receive {:mcp_native_called, _}
  end

  test "ordered raw rich MCP blocks, structured values and public extras survive exactly", ctx do
    raw = rich_result()
    assert {:ok, result} = MCP.execute(operation(ctx))
    assert result.content === raw["content"]
    assert result.structured === raw["structuredContent"]
    assert result.metadata.mcp === Map.drop(raw, ["content", "structuredContent", "isError"])
    assert result.is_error === false
    assert :settled = ToolEffects.settlement({:ok, result}, %{read_only: false})
    assert Jason.encode!(result)

    assert_receive {:mcp_native_called,
                    %{"name" => "echo.raw", "arguments" => %{"text" => "value"}}}
  end

  test "remote isError is a completed native error and never transport uncertainty", ctx do
    raw = %{rich_result() | "isError" => true}
    Agent.update(ctx.state, &%{&1 | response: raw})
    assert {:ok, %{is_error: true, content: content} = result} = MCP.execute(operation(ctx))
    assert content === raw["content"]
    assert :settled = ToolEffects.settlement({:ok, result}, %{read_only: false})
  end

  test "completed malformed and overbudget responses remain settled errors", ctx do
    for response <- [
          %{"content" => "not an MCP content list"},
          %{"content" => [], "isError" => "false"},
          %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 262_145)}]}
        ] do
      Agent.update(ctx.state, &%{&1 | response: response})

      assert {:ok, %{is_error: true, error: %Error{class: class}} = result} =
               MCP.execute(operation(ctx))

      assert class in [:malformed_result, :budget_exceeded]
      assert :settled = ToolEffects.settlement({:ok, result}, %{read_only: false})
    end
  end

  test "malformed and unknown MCP content blocks settle as malformed results", ctx do
    for block <- [
          nil,
          123,
          %{},
          %{"type" => "unknown", "text" => "unrecognized"},
          %{"type" => "text"},
          %{"type" => "text", "text" => 123},
          %{"type" => "text", "text" => "valid", "annotations" => "invalid"},
          %{"type" => "image", "mimeType" => "image/png"},
          %{"type" => "image", "data" => 123, "mimeType" => "image/png"},
          %{"type" => "image", "data" => "aW1hZ2U=", "mimeType" => 123},
          %{"type" => "audio", "data" => "YXVkaW8="},
          %{"type" => "audio", "data" => 123, "mimeType" => "audio/wav"},
          %{"type" => "audio", "data" => "YXVkaW8=", "mimeType" => 123},
          %{"type" => "resource"},
          %{"type" => "resource", "resource" => "invalid"},
          %{"type" => "resource", "resource" => %{"uri" => "memory://empty"}},
          %{"type" => "resource", "resource" => %{"uri" => 123, "text" => "valid"}},
          %{"type" => "resource", "resource" => %{"uri" => "memory://text", "text" => 123}},
          %{"type" => "resource", "resource" => %{"uri" => "memory://blob", "blob" => 123}},
          %{
            "type" => "resource",
            "resource" => %{"uri" => "memory://text", "text" => "valid", "mimeType" => 123}
          },
          %{"type" => "resource_link", "name" => "missing URI"},
          %{"type" => "resource_link", "uri" => 123, "name" => "invalid URI"},
          %{"type" => "resource_link", "uri" => "memory://link"},
          %{"type" => "resource_link", "uri" => "memory://link", "name" => 123}
        ] do
      Agent.update(ctx.state, &%{&1 | response: %{"content" => [block]}})

      assert {:ok, %{is_error: true, error: %Error{class: :malformed_result}} = result} =
               MCP.execute(operation(ctx))

      assert :settled = ToolEffects.settlement({:ok, result}, %{read_only: false})
    end
  end

  test "valid annotated blocks and embedded blob resources retain their exact public maps", ctx do
    annotations = %{"audience" => ["assistant", "user"], "priority" => 0.75}
    blocks = Enum.map(rich_result()["content"], &Map.put(&1, "annotations", annotations))

    blob = %{
      "type" => "resource",
      "annotations" => annotations,
      "resource" => %{
        "uri" => "memory://blob",
        "blob" => "YmxvYg==",
        "mimeType" => "application/octet-stream",
        "_meta" => %{"retained" => true}
      }
    }

    blocks = blocks ++ [blob, %{"type" => "text", "text" => ""}]
    Agent.update(ctx.state, &%{&1 | response: %{"content" => blocks}})

    assert {:ok, %{is_error: false, content: ^blocks}} = MCP.execute(operation(ctx))
  end

  test "dispatched transport errors report unknown outcome without private details", ctx do
    Agent.update(ctx.state, &%{&1 | response: :transport_error})
    assert {:error, %Error{class: :unknown_outcome} = error} = MCP.execute(operation(ctx))
    refute inspect(error) =~ "private transport details"
    assert :uncertain = ToolEffects.settlement({:error, error}, %{read_only: false})
    assert_receive {:mcp_native_called, _}
  end

  test "native context enrichment is accepted while unknown context is rejected", ctx do
    op = put_in(operation(ctx), [:backend_context, :resource_owner_pid], self())
    assert {:ok, _} = MCP.execute(op)
    bad = put_in(operation(ctx), [:backend_context, :foreign], true)
    assert {:rejected, proof} = MCP.execute(bad)
    assert {:ok, %{is_error: true}} = ToolEffects.validate_rejection(proof, bad)
    assert :ok = MCP.cancel(operation(ctx))
  end

  test "effect owner death cancels the caller-owned handle and preserves shared source", ctx do
    Agent.update(ctx.state, &%{&1 | response: :pending})
    task = Task.async(fn -> MCP.execute(operation(ctx)) end)
    assert_receive {:mcp_native_pending, id}, 2_000
    Task.shutdown(task, :brutal_kill)
    assert_receive {:mcp_native_cancelled, %{"requestId" => ^id, "reason" => "owner_down"}}, 2_000
    assert Process.alive?(ctx.pid)
    Agent.update(ctx.state, &%{&1 | response: :rich})
    assert {:ok, _} = MCP.execute(operation(ctx))
  end

  test "native Execution dispatches real MCP and rejects revoked grants without intent", ctx do
    {:ok, descriptors} = MCP.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority(ctx))
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 2})

    record = %{
      run_id: @run,
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      admitted: true,
      current_step: %{step_id: "step", attempt_id: "attempt"},
      deadline: nil,
      outcome: nil,
      context: %{},
      children: []
    }

    input = operation(ctx) |> Map.drop([:backend_context])

    options = [
      registry: bundle.registry,
      authority: authority(ctx),
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2_000,
      cleanup_timeout: 500
    ]

    assert {:ok, _, %{effects: [%{is_error: false, content: content}]}} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               options
             )

    assert content === rich_result()["content"]
    assert_receive {:mcp_native_called, _}

    {:ok, denied_table} = EphemeralStore.new(1)
    denied = Keyword.put(options, :authority, %{authority(ctx) | grants: []})

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               denied_table,
               record,
               %{command: {:tool_invoked, 11, input}},
               denied
             )

    assert :ets.tab2list(denied_table) == []
    refute_receive {:mcp_native_called, _}
  end

  defp operation(ctx) do
    %{
      tool_name: ctx.name,
      tool_revision: ctx.context.source.generation,
      arguments: %{"text" => "value"},
      run_id: @run,
      incarnation: 1,
      catalog_revision: 1,
      backend_context: ctx.context,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_call_id: "tool-call"
    }
  end

  defp authority(ctx),
    do: %{
      caller: "caller",
      run_id: @run,
      grants: [ctx.name],
      tool_revisions: %{ctx.name => ctx.context.source.generation}
    }

  defp schema,
    do: %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}},
      "required" => ["text"],
      "additionalProperties" => false
    }

  defp rich_result do
    %{
      "content" => [
        %{"type" => "text", "text" => "first"},
        %{"type" => "image", "data" => "aW1hZ2U=", "mimeType" => "image/png"},
        %{"type" => "audio", "data" => "YXVkaW8=", "mimeType" => "audio/wav"},
        %{
          "type" => "resource",
          "resource" => %{
            "uri" => "memory://note",
            "mimeType" => "text/plain",
            "text" => "resource text"
          }
        },
        %{"type" => "resource_link", "uri" => "memory://link", "name" => "linked note"},
        %{"type" => "text", "text" => "last"}
      ],
      "structuredContent" => %{"answer" => [1, 2, 3]},
      "isError" => false,
      "_meta" => %{"vendor" => "retained"},
      "public_extra" => %{"is_error" => "unmodified"}
    }
  end
end
