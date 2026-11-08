defmodule Synapsis.Session.NativeHostMemoryGetFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.HostMemory
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Memory.Settings
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "memory::get"
  @record_id "b9a3299b-29da-4e7e-bc8b-c1d4f98a70e1"
  @arguments %{"id" => @record_id}
  @call_id "canonical-host-record"
  @content "Canonical host record.\nKeep the complete second line: 雪 😀.\nFinal line."
  @completion "Canonical record received"
  @prompt "Read the selected canonical host record"
  @replay_prompt "Recall the completed canonical record"
  @description "Read one canonical record by UUID from this host's authorized default memory partition. Requires canonical online access; no offline or recall fallback and no project/session isolation guarantee."
  @schema %{
    "type" => "object",
    "properties" => %{
      "id" => %{
        "type" => "string",
        "minLength" => 36,
        "maxLength" => 36,
        "pattern" => "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
      }
    },
    "required" => ["id"],
    "additionalProperties" => false
  }
  @host_result %{
    "record" => %{
      "id" => @record_id,
      "canonical_id" => @record_id,
      "authority" => "canonical",
      "provisional" => false,
      "kind" => "memory",
      "content" => @content,
      "memory_type" => "semantic",
      "tags" => ["fixture"],
      "lifecycle_state" => "active"
    },
    "mode" => "online",
    "authority" => "canonical",
    "consistency" => "canonical",
    "stale" => false,
    "history_available" => true
  }

  for mode <- [:direct, :deferred] do
    @mode mode
    test "saved v1 #{@mode} host get reaches the model and durable new-Worker replay once",
         %{tmp_dir: root} do
      ctx = setup_context(root, @mode)
      SessionHarness.ensure_running!(ctx.id)
      assert :ok = Worker.send_message(ctx.id, @prompt)
      assert_receive {:host_get_request, 0, initial, handler}, 15_000
      runtime = runtime(ctx.id)
      assert Conversation.status(runtime.root).catalog_revision == 1

      issued =
        :sys.get_state(runtime.adapter).tool_contexts[{runtime.run_id, 1}].snapshot.issued_descriptors

      assert issued[@name].backend == HostMemory
      assert issued[@name].backend_context.catalog_revision == 1
      assert issued[@name].backend_context.source == ctx.source

      {get_request, handler, revision, result_index} =
        if @mode == :deferred do
          assert names(initial) == ["tool_search"]
          send(handler, :deliver)
          assert_receive {:host_get_request, 1, published, handler}, 15_000
          assert names(published) == encoded([@name, "tool_search"])
          assert Conversation.status(runtime.root).catalog_revision == 2
          assert :sys.get_state(runtime.root).catalog.registry.tools[@name] === issued[@name]
          assert output(published, "discover-host-get")["output"] =~ "staged"
          {published, handler, 2, 2}
        else
          assert names(initial) == encoded([@name])
          {initial, handler, 1, 1}
        end

      assert_catalog(get_request)
      send(handler, :deliver)
      assert_receive {:host_get_request, ^result_index, following, handler}, 15_000
      assert output(following, @call_id) == expected_output(ctx)
      assert_call(following)
      send(handler, :deliver)
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000

      expected_use = %ToolUse{tool_use_id: @call_id, tool: @name, input: @arguments}
      expected_result = expected_result(ctx)
      original_parts = tool_parts(ctx.id)

      assert Enum.filter(original_parts, &(&1.tool_use_id == @call_id)) ==
               [expected_use, expected_result]

      assert_round_trips(original_parts)
      assert_durable(ctx.id, original_parts)
      assert_host_calls(ctx)

      assert {:ok, aggregate} =
               Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

      [intent] =
        for {_, intent} <- aggregate.run.execution_intents,
            intent.type == :tool and intent.operation.tool_name == @name,
            do: intent

      assert intent.operation.arguments == @arguments
      assert intent.operation.tool_call_id == @call_id
      assert intent.operation.tool_revision == 1
      assert intent.operation.catalog_revision == revision
      assert intent.operation.run_id == runtime.run_id
      assert intent.operation.incarnation == runtime.binding.run_incarnation
      assert intent.status == :consumed

      monitor = Process.monitor(runtime.worker)
      assert :ok = DynamicSupervisor.stop_session(ctx.id)
      assert_receive {:DOWN, ^monitor, :process, old_worker, _}, 5_000
      assert old_worker == runtime.worker
      SessionHarness.ensure_running!(ctx.id)
      [{fresh, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
      assert fresh != old_worker
      assert :ok = Worker.send_message(ctx.id, @replay_prompt)
      replay_index = result_index + 1
      assert_receive {:host_get_request, ^replay_index, replay, handler}, 15_000
      assert output(replay, @call_id) == expected_output(ctx)
      assert_call(replay)
      send(handler, :deliver)
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert tool_parts(ctx.id) == original_parts
      assert_round_trips(tool_parts(ctx.id))
      assert_durable(ctx.id, original_parts)
      assert_host_calls(ctx)
      assert {:ok, saved} = ConfigStore.get(:agent, ctx.harness.agent_config.id)
      assert saved == ctx.saved_agent
    end
  end

  defp setup_context(root, mode) do
    previous = ConfigStore.get(:memory, "default")
    fixture = Gaoxy.Test.open()
    requests = start_supervised!({Agent, fn -> [] end})
    endpoint = String.trim_trailing(Gaoxy.Test.url(fixture), "/")

    on_exit(fn ->
      case previous do
        {:ok, entry} -> ConfigStore.put(:memory, entry)
        {:error, :not_found} -> ConfigStore.delete(:memory, "default")
      end
    end)

    assert {:ok, _} =
             Settings.save(%{
               "backend" => "workspace",
               "host_agent" => %{
                 "enabled" => true,
                 "endpoint" => endpoint,
                 "agent_id" => "fixture-agent"
               }
             })

    Gaoxy.Test.stub(fixture, "POST", "/memory/fixture-agent/call/get", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(requests, &(&1 ++ [Jason.decode!(body)]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => @host_result}))
    end)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      case Synapsis.Providers.get_by_name(harness.provider.name) do
        {:ok, provider} -> Synapsis.Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    config =
      if mode == :deferred,
        do: Map.put(harness.agent_config.config, "deferred_tool_names", [@name]),
        else: harness.agent_config.config

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})

    assert {:ok, saved} = ConfigStore.get(:agent, harness.agent_config.id)
    assert saved["tools"] == [@name]
    assert saved["tool_contract_version"] == 1

    if mode == :deferred,
      do: assert(Jason.decode!(saved["config"])["deferred_tool_names"] == [@name])

    assert {:ok, _} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "test-key"
             })

    ctx = %{
      harness: harness,
      id: harness.session.id,
      source: %{id: "backplane-host", endpoint: endpoint, agent_id: "fixture-agent"},
      requests: requests,
      fixture: fixture,
      saved_agent: saved
    }

    install_provider(ctx, mode, self())
    SessionHarness.subscribe!(ctx.id)
    ctx
  end

  defp install_provider(ctx, mode, owner) do
    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(ctx.harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:host_get_request, index, request, self()})

      receive do
        :deliver -> :ok
      after
        15_000 -> raise "host get provider handshake timed out"
      end

      case {mode, index} do
        {:deferred, 0} ->
          function_call(conn, "discover-host-get", "tool_search", %{
            "query" => @name,
            "limit" => 1
          })

        {:direct, 0} ->
          function_call(conn, @call_id, @name, @arguments)

        {:deferred, 1} ->
          function_call(conn, @call_id, @name, @arguments)

        _ ->
          sse(conn, [
            %{"type" => "response.output_text.delta", "delta" => @completion},
            completed([])
          ])
      end
    end)
  end

  defp expected_result(ctx) do
    # Public host state uses source_authority in Parts; authority is reserved
    # for native runtime bindings. The backend/domain response stays unchanged.
    structured = %{
      "mode" => "online",
      "source_authority" => "canonical",
      "consistency" => "canonical",
      "stale" => false,
      "history_available" => true,
      "source" => %{
        "id" => "backplane-host",
        "endpoint" => ctx.source.endpoint,
        "partition" => "host_default"
      },
      "record" => %{
        "memory_id" => @record_id,
        "canonical_id" => @record_id,
        "kind" => "memory",
        "source_authority" => "canonical",
        "provisional" => false,
        "content" => @content,
        "memory_type" => "semantic",
        "tags" => ["fixture"],
        "lifecycle_state" => "active",
        "citation" => %{
          "source_id" => "backplane-host",
          "endpoint" => ctx.source.endpoint,
          "memory_id" => @record_id
        }
      }
    }

    %ToolResult{
      tool_use_id: @call_id,
      content: expected_text(ctx),
      is_error: false,
      projection: %{
        "version" => 1,
        "result" => %{
          "content" => expected_text(ctx),
          "structured" => structured,
          "is_error" => false
        }
      }
    }
  end

  defp expected_text(ctx),
    do:
      "Host memory backplane-host (online; authority=canonical; consistency=canonical; stale=false; history_available=true).\n" <>
        @content <> "\nSource: backplane-host #{ctx.source.endpoint} record #{@record_id}"

  defp expected_output(ctx),
    do: %{"type" => "function_call_output", "call_id" => @call_id, "output" => expected_text(ctx)}

  defp output(request, id),
    do:
      Enum.find(request["input"], &(&1["type"] == "function_call_output" and &1["call_id"] == id))

  defp names(request), do: Enum.sort(Enum.map(request["tools"], & &1["name"]))
  defp encoded(names), do: Enum.sort(Enum.map(names, &ToolName.encode/1))

  defp assert_catalog(request),
    do:
      assert(
        Enum.find(request["tools"], &(&1["name"] == ToolName.encode(@name))) ==
          %{
            "type" => "function",
            "name" => ToolName.encode(@name),
            "description" => @description,
            "parameters" => @schema
          }
      )

  defp assert_call(request) do
    [call] =
      Enum.filter(
        request["input"],
        &(&1["type"] == "function_call" and &1["call_id"] == @call_id)
      )

    assert call["name"] == ToolName.encode(@name)
    assert Jason.decode!(call["arguments"]) == @arguments
  end

  defp assert_host_calls(ctx) do
    assert Agent.get(ctx.requests, & &1) == [@arguments]
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
  end

  defp tool_parts(id),
    do:
      for(
        message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
      )

  defp assert_round_trips(parts) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end
  end

  defp assert_durable(id, expected) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    actual =
      for turn <- turns, part <- turn.parts, part[:type] in ~w(tool_use tool_result), do: part

    dumped =
      for part <- expected do
        case part do
          %ToolUse{} ->
            %{
              type: "tool_use",
              id: part.tool_use_id,
              name: part.tool,
              input: part.input,
              status: "pending"
            }

          %ToolResult{} ->
            %{
              type: "tool_result",
              tool_use_id: part.tool_use_id,
              content: part.content,
              is_error: part.is_error,
              projection: part.projection
            }
        end
      end

    assert actual == dumped
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)

    %{
      worker: worker,
      adapter: data.runtime_pid,
      root: state.root,
      binding: state.binding,
      run_id: state.run_id,
      store: state.store
    }
  end

  defp function_call(conn, id, name, arguments) do
    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => ToolName.encode(name),
      "arguments" => Jason.encode!(arguments)
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "arguments", "")
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => item["id"],
        "delta" => item["arguments"]
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
