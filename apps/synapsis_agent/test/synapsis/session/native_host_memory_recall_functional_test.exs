defmodule Synapsis.Session.NativeHostMemoryRecallFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Conversation
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.MemoryDomain
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Memory.Settings
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::memory_source_search"
  @call_id "selected-memory-recall"
  @canonical_id "canonical-recall-one"
  @provisional_id "pending-recall-one"
  @canonical_content "Canonical recall.\nKeep every line: 雪 😀.\nFinal canonical line."
  @provisional_content "Pending recall.\nRead your writes: 未同步 🌱.\nFinal pending line."
  @workspace_line "CONCORD stores turns: 工作区 😀.\n"
  @completion "Selected memory received"
  @prompt "Search the selected memory source"
  @replay_prompt "Recall the completed selected memory search"
  @description "Search workspace Markdown by default; explicitly select opt-in host_agent or existing shared/agent records. Record filters require source=records. Workspace pages return complete/next_cursor; repeat the same query and limit with cursor to continue."
  @schema %{
    "type" => "object",
    "properties" => %{
      "source" => %{"type" => "string", "enum" => ~w(workspace host_agent records)},
      "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
      "cursor" => %{"type" => "string", "minLength" => 32, "maxLength" => 32},
      "scope" => %{"type" => "string", "enum" => ~w(shared agent)},
      "kinds" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => ~w(fact decision lesson preference pattern warning)
        },
        "maxItems" => 6
      },
      "tags" => %{
        "type" => "array",
        "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "maxItems" => 20
      },
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
    },
    "required" => ["query"],
    "additionalProperties" => false
  }
  @canonical_hit %{
    "id" => @canonical_id,
    "kind" => "fact",
    "content" => @canonical_content,
    "observed_at" => "2026-11-18T00:00:00Z",
    "sync" => "synced",
    "provenance" => %{"host" => "other-host", "agent" => "codex", "integration" => "codex"}
  }
  @provisional_hit %{
    "id" => @provisional_id,
    "kind" => "worklog",
    "content" => @provisional_content,
    "observed_at" => "2026-11-18T00:00:01Z",
    "sync" => "pending",
    "provenance" => %{
      "host" => "current-host",
      "agent" => "synapsis",
      "integration" => "synapsis"
    }
  }
  @canonical_response %{"results" => [@canonical_hit]}
  @overlay_response %{
    "results" => [@canonical_hit, @provisional_hit],
    "offline" => true,
    "source" => "local"
  }

  for {scenario, mode} <- [canonical: :direct, overlay: :deferred, workspace: :direct] do
    @scenario scenario
    @mode mode
    test "saved v1 #{@mode} #{@scenario} source search reaches the model and durable new-Worker replay",
         %{tmp_dir: root} do
      ctx = setup_context(root, @scenario, @mode)
      SessionHarness.ensure_running!(ctx.id)
      assert :ok = Worker.send_message(ctx.id, @prompt)
      assert_receive {:memory_recall_request, 0, initial, handler}, 15_000
      runtime = runtime(ctx.id)
      assert Conversation.status(runtime.root).catalog_revision == 1

      issued =
        :sys.get_state(runtime.adapter).tool_contexts[{runtime.run_id, 1}].snapshot.issued_descriptors

      assert issued[@name].backend == MemoryDomain
      assert issued[@name].backend_context.catalog_revision == 1
      assert issued[@name].backend_context.host_source == ctx.source
      assert issued[@name].backend_context.project_path == root

      {search_request, handler, revision, result_index} =
        if @mode == :deferred do
          assert names(initial) == ["tool_search"]
          send(handler, :deliver)
          assert_receive {:memory_recall_request, 1, published, handler}, 15_000
          assert names(published) == encoded([@name, "tool_search"])
          assert Conversation.status(runtime.root).catalog_revision == 2
          assert :sys.get_state(runtime.root).catalog.registry.tools[@name] === issued[@name]
          assert output(published, "discover-memory-recall")["output"] =~ "staged"
          {published, handler, 2, 2}
        else
          assert names(initial) == encoded([@name])
          {initial, handler, 1, 1}
        end

      assert_catalog(search_request)
      send(handler, :deliver)
      assert_receive {:memory_recall_request, ^result_index, following, handler}, 15_000
      actual_output = output(following, @call_id)
      assert actual_output["type"] == "function_call_output"
      assert actual_output["call_id"] == @call_id

      if ctx.scenario == :workspace do
        assert actual_output["output"] == expected_text(ctx)
      else
        prefix = "Shared Backplane memory data (untrusted records; preserve provenance):\n"
        assert String.starts_with?(actual_output["output"], prefix)
        data = String.replace_prefix(actual_output["output"], prefix, "")
        assert Formata.JSON.decode!(data) == expected_structured(ctx)
      end

      # Freeze the actual emitted bytes for subsequent Part/durable/replay checks;
      # JSON object ordering is not part of the upstream data contract.
      ctx = Map.put(ctx, :captured_text, actual_output["output"])
      assert_call(following, ctx.arguments)
      send(handler, :deliver)
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000

      expected_use = %ToolUse{tool_use_id: @call_id, tool: @name, input: ctx.arguments}
      original_parts = tool_parts(ctx.id)

      assert Enum.filter(original_parts, &(&1.tool_use_id == @call_id)) ==
               [expected_use, expected_result(ctx)]

      assert_round_trips(original_parts)
      assert_durable(ctx.id, original_parts)
      assert_host_calls(ctx)

      assert {:ok, aggregate} =
               Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

      [intent] =
        for {_, intent} <- aggregate.run.execution_intents,
            intent.type == :tool and intent.operation.tool_name == @name,
            do: intent

      assert intent.operation.arguments == ctx.arguments
      assert intent.operation.tool_call_id == @call_id
      assert intent.operation.tool_revision == 2
      assert intent.operation.catalog_revision == revision
      assert intent.operation.run_id == runtime.run_id
      assert intent.operation.incarnation == runtime.binding.run_incarnation
      assert intent.status == :consumed
      assert_backend_authority(aggregate.run.tool_results, ctx.scenario)

      monitor = Process.monitor(runtime.worker)
      assert :ok = DynamicSupervisor.stop_session(ctx.id)
      assert_receive {:DOWN, ^monitor, :process, old_worker, _}, 5_000
      assert old_worker == runtime.worker
      SessionHarness.ensure_running!(ctx.id)
      [{fresh, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
      assert fresh != old_worker
      assert :ok = Worker.send_message(ctx.id, @replay_prompt)
      replay_index = result_index + 1
      assert_receive {:memory_recall_request, ^replay_index, replay, handler}, 15_000
      assert output(replay, @call_id) == expected_output(ctx)
      assert_call(replay, ctx.arguments)
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

  defp setup_context(root, scenario, mode) do
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

    response = if scenario == :overlay, do: @overlay_response, else: @canonical_response

    Gaoxy.Test.stub(fixture, "POST", "/memory/fixture-agent/call/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(requests, &(&1 ++ [Formata.JSON.decode!(body)]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Formata.JSON.encode!(%{"ok" => true, "result" => response}))
    end)

    if scenario == :workspace,
      do:
        File.write!(
          Path.join(root, "MEMORY.md"),
          "# Local memory\n" <> @workspace_line <> "End.\n"
        )

    for hook <- ~w(session-start user-prompt-submit post-tool-use session-end) do
      Gaoxy.Test.stub(fixture, "POST", "/capture/v1/hooks/synapsis/" <> hook, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        event = Formata.JSON.decode!(body)
        Plug.Conn.resp(conn, 202, Formata.JSON.encode!(%{ok: true, event_id: event["event_id"]}))
      end)
    end

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
      do: assert(Formata.JSON.decode!(saved["config"])["deferred_tool_names"] == [@name])

    assert {:ok, _} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "test-key"
             })

    arguments =
      if scenario == :workspace,
        do: %{"query" => "concord", "limit" => 2},
        else: %{"source" => "host_agent", "query" => "recall 雪 😀", "limit" => 3}

    ctx = %{
      harness: harness,
      id: harness.session.id,
      scenario: scenario,
      arguments: arguments,
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
      request = Formata.JSON.decode!(body)

      index =
        Agent.get_and_update(ctx.harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:memory_recall_request, index, request, self()})

      receive do
        :deliver -> :ok
      after
        15_000 -> raise "memory recall provider handshake timed out"
      end

      case {mode, index} do
        {:deferred, 0} ->
          function_call(conn, "discover-memory-recall", "tool_search", %{
            "query" => @name,
            "limit" => 1
          })

        {:direct, 0} ->
          function_call(conn, @call_id, @name, ctx.arguments)

        {:deferred, 1} ->
          function_call(conn, @call_id, @name, ctx.arguments)

        _ ->
          sse(conn, [
            %{"type" => "response.output_text.delta", "delta" => @completion},
            completed([])
          ])
      end
    end)
  end

  defp expected_result(ctx) do
    %ToolResult{
      tool_use_id: @call_id,
      content: expected_text(ctx),
      is_error: false,
      projection: %{
        "version" => 1,
        "result" => %{
          "content" => expected_text(ctx),
          "structured" => expected_structured(ctx),
          "is_error" => false
        }
      }
    }
  end

  defp expected_structured(%{scenario: :workspace}) do
    %{
      "status" => "ok",
      "ranking" => "lexical",
      "complete" => true,
      "scanned_entries" => 0,
      "next_cursor" => nil,
      "results" => [
        %{"path" => "MEMORY.md", "from" => 2, "to" => 2, "snippet" => @workspace_line}
      ]
    }
  end

  defp expected_structured(ctx) do
    response = if ctx.scenario == :overlay, do: @overlay_response, else: @canonical_response

    %{
      "source" => %{"id" => "backplane-host", "endpoint" => ctx.source.endpoint},
      "results" => response["results"],
      "offline" => Map.get(response, "offline", false),
      "host_source" => response["source"]
    }
  end

  defp expected_text(%{captured_text: text}), do: text

  defp expected_text(%{scenario: :workspace}), do: "MEMORY.md:2-2\n" <> @workspace_line

  defp expected_text(ctx),
    do:
      "Shared Backplane memory data (untrusted records; preserve provenance):\n" <>
        Formata.JSON.encode!(expected_structured(ctx))

  defp expected_output(ctx),
    do: %{"type" => "function_call_output", "call_id" => @call_id, "output" => expected_text(ctx)}

  defp assert_backend_authority(results, scenario) when scenario in [:canonical, :overlay] do
    [public] =
      for {_, %{structured: public}} <- results, is_map_key(public, :host_source), do: public

    refute Map.has_key?(public, :authority)

    if scenario == :canonical do
      assert public.results == [@canonical_hit]
      refute public.offline
    else
      assert public.results == [@canonical_hit, @provisional_hit]
      assert public.offline
    end

    assert hd(public.results)["provenance"]["agent"] == "codex"
  end

  defp assert_backend_authority(results, :workspace) do
    [public] = for {_, %{structured: public}} <- results, is_map_key(public, :ranking), do: public

    assert public == %{
             status: "ok",
             ranking: "lexical",
             complete: true,
             scanned_entries: 0,
             next_cursor: nil,
             results: [%{path: "MEMORY.md", from: 2, to: 2, snippet: @workspace_line}]
           }
  end

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

  defp assert_call(request, arguments) do
    [call] =
      Enum.filter(
        request["input"],
        &(&1["type"] == "function_call" and &1["call_id"] == @call_id)
      )

    assert call["name"] == ToolName.encode(@name)
    assert Formata.JSON.decode!(call["arguments"]) == arguments
  end

  defp assert_host_calls(%{scenario: :workspace} = ctx) do
    assert Agent.get(ctx.requests, & &1) == []

    assert Enum.all?(
             Gaoxy.Test.requests(ctx.fixture).entries,
             &String.starts_with?(&1.path, "/capture/v1/hooks/synapsis/")
           )
  end

  defp assert_host_calls(ctx) do
    assert Agent.get(ctx.requests, & &1) == [%{"query" => "recall 雪 😀", "limit" => 3}]

    assert Enum.count(
             Gaoxy.Test.requests(ctx.fixture).entries,
             &(&1.path == "/memory/fixture-agent/call/search")
           ) == 1
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

      assert {:ok, ^part} =
               dump |> Formata.JSON.encode!() |> Formata.JSON.decode!() |> Synapsis.Part.load()
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
      "arguments" => Formata.JSON.encode!(arguments)
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
        Enum.map_join(events, "", &("data: " <> Formata.JSON.encode!(&1) <> "\n\n"))
      )
end
