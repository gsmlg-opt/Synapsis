defmodule Synapsis.Session.NativeMCPResourcesFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}
  alias Synapsis.MCP.Server
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @names ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource)
  @cursor "頁/opaque+雪?next=é=="
  @uri "fixture://資料/雪?part=é+1"

  test "selected resource sources retain aggregate pages, native contracts and durable effect-free replay",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    source_a = start_source("a")
    source_b = start_source("b")
    sources = [source_b, source_a]

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(harness)
      after
        for source <- sources do
          Synapsis.MCP.stop(source.config.name)
          Synapsis.MCPConfigs.delete(source.config)
        end
      end
    end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(
               harness.agent_config,
               %{
                 tools: @names,
                 config:
                   Map.put(
                     harness.agent_config.config,
                     "mcp_resource_source_ids",
                     Enum.map(sources, & &1.config.id)
                   )
               }
             )

    calls = [
      {"resources-all", "list_mcp_resources", %{}},
      {"templates-all", "list_mcp_resource_templates", %{}},
      {"resources-next", "list_mcp_resources",
       %{"server" => source_a.config.id, "cursor" => @cursor}},
      {"resource-read", "read_mcp_resource", %{"server" => source_b.config.id, "uri" => @uri}},
      {"resources-cursor-all", "list_mcp_resources", %{"cursor" => @cursor}}
    ]

    expected = [
      envelope(sources, "resources/list", %{}),
      envelope(sources, "resources/templates/list", %{}),
      envelope([source_a], "resources/list", %{"cursor" => @cursor}),
      envelope([source_b], "resources/read", %{"uri" => @uri}),
      envelope(sources, "resources/list", %{"cursor" => @cursor})
    ]

    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Read explicitly selected resources")
    requests = for index <- 0..5, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_receive {:resource_descriptors, descriptors}, 5_000
    assert Enum.sort(Map.keys(descriptors)) == Enum.sort(@names)

    for name <- @names do
      assert name in Profiles.supported_names()
      assert Enum.any?(DisplayCatalog.list(), &(&1.name == name))
      descriptor = descriptors[name]
      assert descriptor.backend == Backend
      assert descriptor.tool_revision == 1
      assert descriptor.backend_context.family == :dynamic
      assert descriptor.backend_context.session_binding.run_id != ""
      tool = Enum.find(hd(requests)["tools"], &(ToolName.decode(&1["function"]["name"]) == name))
      assert tool["function"]["parameters"] == descriptor.schema
      properties = if name == "read_mcp_resource", do: ~w(server uri), else: ~w(cursor server)
      assert Enum.sort(Map.keys(descriptor.schema["properties"])) == properties
      required = if name == "read_mcp_resource", do: ~w(server uri), else: []
      assert descriptor.schema["required"] == required
    end

    parts = parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))
    assert Enum.map(results, &Jason.decode!(&1.content)) == expected
    assert Enum.all?(results, &(&1.is_error == false))

    for {result, raw} <- Enum.zip(results, expected) do
      assert result.projection == %{
               "version" => 1,
               "result" => %{
                 "content" => result.content,
                 "structured" => raw,
                 "is_error" => false
               }
             }
    end

    for {wire, count} <- Enum.with_index(requests),
        do: assert_wire(wire, Enum.take(calls, count), Enum.take(results, count))

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(harness.session.id, uses, results)
    effects = effects(sources)
    assert_effects(source_a, source_b, effects)

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    {_, worker_data} = :sys.get_state(old_worker)
    runtime = :sys.get_state(worker_data.runtime_pid)
    assert [%{pid: dynamic, binding: binding}] = Map.values(runtime.mcp_resource_runtimes)
    assert dynamic == descriptors["list_mcp_resources"].backend_context.runtime
    assert Process.alive?(dynamic)
    assert :ok = Worker.send_message(harness.session.id, "Recall the resource pages")
    ordinary = request(6)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire(ordinary, calls, results)
    reused = :sys.get_state(worker_data.runtime_pid)
    assert [%{pid: ^dynamic}] = Map.values(reused.mcp_resource_runtimes)
    assert effects(sources) == effects

    assert {:ok, %{status: :confirmed}} =
             Backplane.AgentRuntime.Codex.Session.close(binding.session)

    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
             Backplane.AgentRuntime.Codex.Session.status(binding.session)

    refute Process.alive?(dynamic)

    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    refute Process.alive?(dynamic)
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute old_worker == new_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall after reopening")
    replay = request(7)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire(replay, calls, results)
    assert effects(sources) == effects
    assert_durable(harness.session.id, uses, results)

    assert parts(harness.session.id) ==
             parts ++
               [
                 %Text{content: "Recall the resource pages"},
                 %Text{content: "Resources complete"},
                 %Text{content: "Recall after reopening"},
                 %Text{content: "Resources complete"}
               ]

    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 8
  end

  test "omitted resource source configuration returns the ordinary empty source envelope",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(
               harness.agent_config,
               %{tools: ["list_mcp_resources"]}
             )

    calls = [{"empty-resources", "list_mcp_resources", %{}}]
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "List the configured resources")
    first = request(0)
    next = request(1)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert [%{"function" => %{"name" => wire_name}}] = first["tools"]
    assert ToolName.decode(wire_name) == "list_mcp_resources"

    assert [%ToolResult{is_error: false} = result] =
             Enum.filter(parts(harness.session.id), &match?(%ToolResult{}, &1))

    assert Jason.decode!(result.content) == %{"sources" => []}
    assert result.projection["result"]["structured"] == %{"sources" => []}
    assert_wire(next, calls, [result])
  end

  defp start_source(label) do
    requests =
      start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: {:requests, label}))

    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      Agent.update(requests, &(&1 ++ [req]))

      result =
        case req["method"] do
          "initialize" ->
            %{
              "protocolVersion" => req["params"]["protocolVersion"],
              "capabilities" => %{"resources" => %{"listChanged" => false, "subscribe" => false}},
              "serverInfo" => %{"name" => "resources-" <> label, "version" => "1"}
            }

          method
          when method in ["resources/list", "resources/templates/list", "resources/read"] ->
            page(label, method, req["params"] || %{})

          "notifications/initialized" ->
            %{}
        end

      if Map.has_key?(req, "id") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    assert {:ok, config} =
             Synapsis.MCPConfigs.create(%{
               name:
                 "native-resources-#{label}-#{System.unique_integer([:positive, :monotonic])}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, server} = Synapsis.MCP.start(config)
    assert :ok = Server.await_ready(server)
    assert {:ok, %{tools: []}} = Synapsis.MCP.runtime_snapshot(config.id)
    %{config: config, label: label, requests: requests}
  end

  defp page(label, "resources/list", params) do
    %{
      "resources" => [
        %{
          "uri" => @uri,
          "name" => label <> " 雪\r\n🎥",
          "mimeType" => "text/plain",
          "annotations" => %{"audience" => ["user"], "priority" => 0.5},
          "_meta" => %{"fixture/descriptor" => [2, 1]}
        }
      ],
      "nextCursor" => @cursor,
      "_meta" => %{"fixture/page" => label},
      "fixture/extension" => %{"cursor" => params["cursor"], "retained" => true}
    }
  end

  defp page(label, "resources/templates/list", _params) do
    %{
      "resourceTemplates" => [
        %{
          "uriTemplate" => "fixture://資料/{id}{?language}",
          "name" => label <> " template",
          "mimeType" => "text/plain",
          "_meta" => %{"fixture/template" => ["日本語", "English"]}
        }
      ],
      "nextCursor" => @cursor,
      "_meta" => %{"fixture/page" => label}
    }
  end

  defp page(label, "resources/read", params) do
    %{
      "contents" => [
        %{
          "uri" => params["uri"],
          "mimeType" => "text/plain; charset=utf-8",
          "text" => label <> " 原文 αβ\r\n🎼",
          "_meta" => %{"fixture/part" => 1}
        },
        %{
          "uri" => params["uri"],
          "mimeType" => "application/octet-stream",
          "blob" => Base.encode64(<<0, 255, 17, 128>>),
          "_meta" => %{"fixture/part" => 2}
        }
      ],
      "_meta" => %{"fixture/order" => ["text", "blob"]}
    }
  end

  defp envelope(sources, method, params),
    do: %{
      "sources" =>
        Enum.map(
          sources,
          &%{"server" => &1.config.id, "result" => page(&1.label, method, params)}
        )
    }

  defp install_provider(harness, calls) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [req]}}
        end)

      send(owner, {:resource_request, index, req})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker)
        runtime = :sys.get_state(data.runtime_pid)
        send(owner, {:resource_descriptors, :sys.get_state(runtime.root).catalog.registry.tools})
      end

      completed = Enum.count(req["messages"], &(&1["role"] == "tool"))

      chunks =
        case Enum.at(calls, completed) do
          {id, name, args} ->
            [
              DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          nil ->
            [
              DeterministicProvider.text_chunk("Resources complete"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp request(index) do
    assert_receive {:resource_request, ^index, request}, 20_000
    request
  end

  defp effects(sources),
    do:
      Map.new(sources, fn source ->
        {source.label,
         Agent.get(source.requests, fn requests ->
           for req <- requests,
               req["method"] in ["resources/list", "resources/templates/list", "resources/read"],
               do: {req["method"], Map.delete(req["params"] || %{}, "_meta")}
         end)}
      end)

  defp assert_effects(a, b, effects) do
    assert effects[a.label] == [
             {"resources/list", %{}},
             {"resources/templates/list", %{}},
             {"resources/list", %{"cursor" => @cursor}},
             {"resources/list", %{"cursor" => @cursor}}
           ]

    assert effects[b.label] == [
             {"resources/list", %{}},
             {"resources/templates/list", %{}},
             {"resources/read", %{"uri" => @uri}},
             {"resources/list", %{"cursor" => @cursor}}
           ]
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_wire(req, calls, results) do
    uses = for message <- req["messages"], call <- List.wrap(message["tool_calls"]), do: call

    assert Enum.map(uses, fn call ->
             {call["id"], ToolName.decode(call["function"]["name"]),
              Jason.decode!(call["function"]["arguments"])}
           end) == calls

    actual = for message <- req["messages"], message["role"] == "tool", do: message

    assert actual ==
             Enum.map(
               results,
               &%{"role" => "tool", "tool_call_id" => &1.tool_use_id, "content" => &1.content}
             )
  end

  defp assert_durable(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.map(Enum.filter(raw, &(&1[:type] == "tool_use")), &{&1.id, &1.name, &1.input}) ==
             Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.map(
             Enum.filter(raw, &(&1[:type] == "tool_result")),
             &{&1.tool_use_id, &1.content, &1.projection}
           ) ==
             Enum.map(results, &{&1.tool_use_id, &1.content, &1.projection})
  end
end
