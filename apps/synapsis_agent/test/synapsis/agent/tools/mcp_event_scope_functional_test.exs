defmodule Synapsis.Agent.Tools.MCPEventScopeFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, ToolCatalog}

  alias Backplane.AgentRuntime.Codex.{
    CodeMode,
    DynamicRuntime,
    Headless,
    ResourceRegistry,
    Session
  }

  alias Backplane.McpProtocol.Client
  alias Synapsis.Agent.Runtime.Store

  @version "2026-07-28"
  @first_cursor "opaque/first+雪"
  @second_cursor "opaque/next?label=汉字+é"
  @server "events-fixture-explicit"
  @request_meta %{
    "synapsis/events" => %{"label" => "汉字\r\n🎥", "nested" => [1, true, %{"雪" => "é"}]}
  }

  # This fixture selects its own server explicitly. It installs no production
  # Events adapter or source-selection policy in Synapsis.
  defmodule Adapter do
    alias Backplane.AgentRuntime.Codex.DynamicRuntime
    alias Backplane.McpProtocol.Client

    def list_events(arguments, operation) do
      context = operation.backend_context
      client = Map.fetch!(context.event_clients, arguments["server"])

      result =
        DynamicRuntime.event_request(operation, fn reserved ->
          options =
            Keyword.merge(
              [cursor: arguments["cursor"], meta: context.event_meta],
              reserved
            )

          {:ok, handle} = started = Client.start_list_events(client, options)
          {:ok, identity} = Client.event_request_identity(handle)

          send(
            context.event_observer,
            {:event_started, operation, self(), handle.owner, handle.client, identity, options}
          )

          started
        end)

      # The public helper returns only the MCP response after its own validated,
      # single-consumption retirement. Do not query or retire its handle again.
      send(context.event_observer, {:event_helper_returned, operation.invocation_id, result})
      {:ok, response} = result
      {:ok, response.result}
    end
  end

  defmodule Provider do
    def stream(request, %{observer: observer}) do
      send(observer, {:event_provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule ObservedStore do
    @behaviour Backplane.AgentRuntime.Store

    defdelegate mode(), to: Store
    defdelegate capabilities(), to: Store
    defdelegate new(incarnation), to: Store
    defdelegate load(context, run_id, opts), to: Store

    def store(context, record, meta),
      do: observe(context, meta, Store.store(context, record, meta))

    def acknowledge_commit(context, stage, meta),
      do: observe(context, meta, Store.acknowledge_commit(context, stage, meta))

    # Hold the return of a successful real Concord commit, never invent an ACK.
    defp observe(context, %{command: {kind, _, input}}, {:ok, acknowledgement} = result) do
      if kind in [:tool_invoked, :tool_completed] and input[:tool_name] == "mcp_events" do
        send(
          context.test_pid,
          {:event_commit_ready, kind, input, acknowledgement.revision, self()}
        )

        receive do
          {:release_event_ack, ^kind} -> :ok
        after
          5_000 -> raise "ordinary Events Store observation was not released"
        end
      end

      send(context.test_pid, {:event_store_ack, kind, acknowledgement.revision})
      result
    end

    defp observe(_context, _meta, result), do: result
  end

  test "native Conversation preserves complete Events pages after real intent and result ACKs" do
    source = start_source()

    %{binding: binding, session: session, dynamic: dynamic, authority: authority, store: store} =
      setup_runtime(["mcp_events"])

    assert Adapter.__info__(:functions) == [list_events: 2]

    assert {:ok, profile} =
             Codex.profile(
               :dynamic,
               %{dynamic_runtime: dynamic, session_binding: binding},
               authority,
               tools: ["mcp_events"]
             )

    original = Map.fetch!(profile.registry.tools, "mcp_events")
    descriptor = with_fixture_context(original, source)
    assert descriptor.backend == Codex.Backend
    assert descriptor.backend_context.family == :dynamic
    assert descriptor.backend_context.runtime == dynamic
    assert descriptor.backend_context.session_binding == binding

    assert descriptor.schema == %{
             "type" => "object",
             "properties" => %{
               "server" => %{"type" => "string", "minLength" => 1},
               "cursor" => %{"type" => "string"}
             },
             "required" => ["server"],
             "additionalProperties" => false
           }

    assert descriptor.schema == original.schema

    assert {:ok, admitted} =
             ToolCatalog.admit_batch([descriptor],
               mode: :strict,
               authority: profile.authority,
               run_id: authority.run_id
             )

    assert admitted.registry.tools["mcp_events"] == descriptor

    conversation =
      start_supervised!(
        {Conversation,
         runtime_options(admitted, binding, store) ++
           [provider: Provider, provider_context: %{observer: self()}]}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "List both explicit fixture Events pages")
    assert_receive {:event_provider, first_request, first_provider}, 3_000
    assert [%{name: "mcp_events", parameters: parameters}] = first_request.tools
    assert parameters == original.schema

    {last_request, last_provider, invocation_ids} =
      Enum.reduce(
        [{@first_cursor, first_page()}, {@second_cursor, second_page()}],
        {first_request, first_provider, []},
        fn {cursor, page}, {_request, provider, ids} ->
          call_id = "events-page-#{length(ids) + 1}"
          arguments = %{"server" => @server, "cursor" => cursor}

          send(provider, {:events, [call(call_id, arguments), done()]})
          intent = hold_intent(store, authority.run_id, arguments)
          assert intent.operation.enclosing_invocation_id == intent.operation.invocation_id
          release_ack(intent, :tool_invoked)
          assert_request_started(source, intent.operation, cursor)
          completed = hold_result(store, authority.run_id, intent.operation, page)
          refute_receive {:event_provider, _, _}, 0
          release_ack(completed, :tool_completed)
          assert_receive {:event_provider, next_request, next_provider}, 5_000
          result = next_request.messages |> Enum.reverse() |> Enum.find(&(&1[:role] == :tool))
          assert result.tool_call_id == call_id
          assert result.result == Map.put(page, :is_error, false)
          {next_request, next_provider, ids ++ [intent.operation.invocation_id]}
        end
      )

    assert Enum.map(Enum.filter(last_request.messages, &(&1[:role] == :tool)), & &1.result) == [
             Map.put(first_page(), :is_error, false),
             Map.put(second_page(), :is_error, false)
           ]

    send(last_provider, {:events, [done()]})
    status = await_completed(conversation, System.monotonic_time(:millisecond) + 5_000)
    assert_durable(store, authority.run_id, status, invocation_ids, [first_page(), second_page()])
    assert_normal_close(session)
    assert_shared_client(source)
    assert {:ok, saved} = Store.load(store, authority.run_id)
    assert saved.run == status.run
  end

  test "provider-free Headless nests the actual Events helper and closes its Deno worker normally" do
    source = start_source()
    selection = ~w(exec wait mcp_events)

    %{binding: binding, session: session, dynamic: dynamic, authority: authority, store: store} =
      setup_runtime(selection)

    # Start from the upstream dynamic contract, retaining its backend and schema.
    [event_contract] =
      DynamicRuntime.contracts(%{dynamic_runtime: dynamic})
      |> Enum.filter(&(&1.name == "mcp_events"))
      |> Enum.map(&with_fixture_context(&1, source))

    assert {:ok, catalog} =
             Codex.profile(
               :code_mode_only,
               %{
                 session_binding: binding,
                 deno_path: System.find_executable("deno"),
                 code_mode_contracts: [event_contract],
                 timeout: 10_000
               },
               authority,
               tools: selection
             )

    assert catalog.registry.tools["mcp_events"].backend == Codex.Backend
    assert catalog.registry.tools["mcp_events"].backend_context.family == :dynamic
    assert catalog.registry.tools["mcp_events"].backend_context.session_binding == binding
    assert catalog.registry.tools["mcp_events"].schema == event_contract.schema
    assert {:ok, occurrence} = Headless.start_link(runtime_options(catalog, binding, store))

    on_exit(fn ->
      if Process.alive?(occurrence), do: GenServer.stop(occurrence, :normal, 5_000)
    end)

    source_code = """
    const page = await tools.mcp_events({server: input.server, cursor: input.cursor});
    text(page);
    return page;
    """

    arguments = %{"server" => @server, "cursor" => @first_cursor}
    assert {:ok, %{incarnation: 1}} = Headless.execute(occurrence, source_code, input: arguments)
    intent = hold_intent(store, authority.run_id, arguments)
    assert is_binary(intent.operation.enclosing_invocation_id)
    assert {:ok, aggregate} = Store.load(store, authority.run_id)
    outer = aggregate.run.execution_intents["tool:#{intent.operation.enclosing_invocation_id}"]
    assert outer.operation.tool_name == "exec"

    assert {:ok, workers} = ResourceRegistry.worker_supervisor(binding.resource_registry)
    assert [{_, worker, _, _}] = DynamicSupervisor.which_children(workers)
    assert {:ok, os_identity} = CodeMode.Worker.os_identity(worker)
    assert Process.alive?(worker)
    assert File.exists?("/proc/#{os_identity.pid}")
    monitor = Process.monitor(worker)
    release_ack(intent, :tool_invoked)
    owner = assert_request_started(source, intent.operation, @first_cursor)
    assert owner != worker
    completed = hold_result(store, authority.run_id, intent.operation, first_page())
    release_ack(completed, :tool_completed)

    assert {:ok, result} = Headless.await(occurrence, timeout: 10_000)
    assert result.status == :completed
    assert result.nested_invocations == 1
    assert result.outer_reservations == 1
    # Conversation stores tool_result(normalized) with is_error, but replies to
    # CodeMode with consumer_result(normalized, presentation): the original page.
    expected = first_page()
    assert result.value == expected
    assert [%{"type" => "text", "text" => output}] = result.output
    assert Jason.decode!(output) == expected
    assert result.output_truncated == false
    status = Headless.status(occurrence)
    assert status.phase == :terminal
    assert status.run.state == :completed
    assert status.resource_cleanup == :confirmed
    assert {:ok, saved} = Store.load(store, authority.run_id)
    assert saved.run == status.run
    assert saved.run.context.execution_mode == :headless
    assert saved.run.context.conversation.headless_result == result

    assert saved.run.tool_results[intent.operation.invocation_id] ==
             Map.put(first_page(), :is_error, false)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    refute File.exists?("/proc/#{os_identity.pid}")
    assert_normal_close(session)
    assert_shared_client(source)
    assert {:ok, ^saved} = Store.load(store, authority.run_id)
  end

  defp setup_runtime(selection) do
    assert :ok = Synapsis.Session.Store.ensure_started()
    assert {:ok, store} = Store.new(1)
    store = Map.put(store, :test_pid, self())
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    session = start_supervised!({Session, owner_pid: self()})

    authority = %{
      caller: "events-native-fixture",
      run_id: Ecto.UUID.generate(),
      grants: selection,
      tool_revision: 1
    }

    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)
    %{dynamic: dynamic, session: session, binding: binding, authority: authority, store: store}
  end

  defp with_fixture_context(descriptor, source) do
    context =
      Map.merge(descriptor.backend_context, %{
        event_clients: %{@server => source.client},
        event_observer: self(),
        event_meta: @request_meta
      })

    %{descriptor | backend_context: context}
  end

  defp runtime_options(catalog, binding, store) do
    [
      run_id: binding.run_id,
      incarnation: 1,
      session_binding: binding,
      registry: catalog.registry,
      tools: catalog.tools,
      authority: catalog.authority,
      store: ObservedStore,
      context: store,
      subscriber: self(),
      work: 8,
      run_timeout: 30_000,
      effect_timeout: 15_000,
      commit_timeout: 10_000,
      cleanup_timeout: 5_000
    ]
  end

  defp hold_intent(store, run_id, arguments) do
    assert_receive {:event_commit_ready, :tool_invoked, input, revision, writer}, 5_000
    assert {:ok, saved} = Store.load(store, run_id)
    assert saved.revision == revision
    intent = saved.run.execution_intents["tool:#{input.invocation_id}"]
    assert intent.operation.tool_name == "mcp_events"
    assert intent.operation.arguments == arguments
    assert intent.operation.run_id == run_id
    assert intent.operation.incarnation == 1
    refute Map.has_key?(saved.run.tool_results, input.invocation_id)
    refute_receive {:event_started, _, _, _, _, _, _}, 0
    refute_receive {:events_http, "events/list", _, _, _}, 0
    %{operation: intent.operation, writer: writer, revision: revision}
  end

  defp release_ack(%{writer: writer, revision: revision}, kind) do
    send(writer, {:release_event_ack, kind})
    assert_receive {:event_store_ack, ^kind, ^revision}, 1_000
  end

  defp assert_request_started(source, operation, cursor) do
    invocation_id = operation.invocation_id
    assert_receive {:event_started, actual, owner, owner, client, identity, options}, 5_000
    assert actual.invocation_id == invocation_id
    assert actual.enclosing_invocation_id == operation.enclosing_invocation_id
    assert actual.run_id == operation.run_id
    assert actual.incarnation == 1
    assert client == source.client_pid
    assert owner != self()
    assert identity.method == "events/list"
    assert Enum.all?(Map.values(identity), &(is_binary(&1) and &1 != ""))
    assert options[:track_retirement] == true
    assert is_integer(options[:retirement_deadline])
    assert options[:timeout] in 1..15_000
    assert options[:registration_timeout] in 1..5_000
    assert options[:cursor] == cursor
    assert options[:meta] == @request_meta
    assert_receive {:events_http, "events/list", params, headers, request_id}, 5_000
    assert identity.request_id == request_id
    assert params["cursor"] == cursor
    assert params["_meta"]["synapsis/events"] == @request_meta["synapsis/events"]
    assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
    assert headers["mcp-method"] == "events/list"
    owner
  end

  defp hold_result(store, run_id, operation, page) do
    id = operation.invocation_id
    assert_receive {:event_helper_returned, ^id, {:ok, response}}, 5_000
    assert response.result == page
    assert_receive {:event_commit_ready, :tool_completed, input, revision, writer}, 5_000
    assert input.invocation_id == id
    assert {:ok, saved} = Store.load(store, run_id)
    assert saved.revision == revision
    assert saved.run.tool_results[id] == Map.put(page, :is_error, false)
    %{writer: writer, revision: revision}
  end

  defp assert_durable(store, run_id, status, ids, pages) do
    assert {:ok, saved} = Store.load(store, run_id)
    assert saved.run == status.run
    assert saved.revision == status.run.expected_revision
    assert saved.run.context.conversation.messages == status.messages
    results = for message <- status.messages, message[:role] == :tool, do: message.result
    assert results == Enum.map(pages, &Map.put(&1, :is_error, false))
    assert Enum.map(ids, &saved.run.tool_results[&1]) == results
    assert {:ok, ^saved} = Synapsis.Runtime.Store.load(store.namespace, run_id)
  end

  defp assert_shared_client(source) do
    assert {:ok, handle} =
             Client.start_list_resources(source.client, cursor: "ordinary/resource+雪")

    assert {:ok, resources} = Client.await_resource_request(handle, 2_000)
    assert resources.result == resource_page()
    assert_receive {:events_http, "resources/list", params, headers, _id}, 1_000
    assert params["cursor"] == "ordinary/resource+雪"
    assert headers["mcp-method"] == "resources/list"
    assert {:ok, tools} = Client.list_tools(source.client)
    assert tools.result == tool_page()
    assert_receive {:events_http, "tools/list", _, headers, _id}, 1_000
    assert headers["mcp-method"] == "tools/list"
    assert Process.alive?(source.client_pid)
    assert Process.whereis(source.client) == source.client_pid
    assert Process.alive?(source.supervisor)
    Gaoxy.Test.verify!(source.fixture)
  end

  defp assert_normal_close(session) do
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} = Session.status(session)
  end

  defp await_completed(conversation, deadline) do
    case Conversation.status(conversation) do
      %{phase: :terminal, run: %{state: :completed}, resource_cleanup: :confirmed} = status ->
        status

      status ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(status)
        Process.sleep(10)
        await_completed(conversation, deadline)
    end
  end

  defp call(id, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{id: id, name: "mcp_events", arguments: arguments}
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp start_source() do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    Gaoxy.Test.stub(fixture, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    Gaoxy.Test.stub(fixture, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wire = Jason.decode!(body)
      headers = Map.new(conn.req_headers)
      send(owner, {:events_http, wire["method"], wire["params"], headers, wire["id"]})

      if Map.has_key?(wire, "id") do
        result = result(wire)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => wire["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    name = String.to_atom("SynapsisEventsNative151#{System.unique_integer([:positive])}")

    supervisor =
      start_supervised!(
        {Client,
         name: name,
         transport: {:streamable_http, url: Gaoxy.Test.url(fixture, "/mcp")},
         one_shot: true,
         activation_id: "events-functional-#{name}",
         client_info: %{"name" => "synapsis-events-functional", "version" => "1"},
         capabilities: %{},
         protocol_version: @version,
         timeout: 3_000}
      )

    assert :ok = Client.await_ready(name, timeout: 3_000)
    assert_receive {:events_http, "server/discover", discovery, discovery_headers, _id}, 3_000
    assert discovery["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
    assert discovery_headers["mcp-method"] == "server/discover"

    %{fixture: fixture, client: name, client_pid: Process.whereis(name), supervisor: supervisor}
  end

  defp result(%{"method" => "server/discover"}) do
    %{
      "resultType" => "complete",
      "supportedVersions" => [@version],
      "capabilities" => %{"resources" => %{}, "tools" => %{}, "events" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    }
  end

  defp result(%{"method" => "events/list", "params" => %{"cursor" => @first_cursor}}),
    do: first_page()

  defp result(%{"method" => "events/list", "params" => %{"cursor" => @second_cursor}}),
    do: second_page()

  defp result(%{"method" => "resources/list"}), do: resource_page()
  defp result(%{"method" => "tools/list"}), do: tool_page()

  defp first_page do
    %{
      "resultType" => "complete",
      "events" => [
        %{
          "name" => "comment.created",
          "description" => "汉字\r\nfirst 🎥",
          "delivery" => ["webhook"],
          "inputSchema" => %{"type" => "object"},
          "payloadSchema" => true,
          "synapsis/descriptor" => %{"label" => "雪"}
        },
        %{
          "name" => "comment.updated",
          "description" => "é — 更新",
          "delivery" => ["webhook", "other"],
          "inputSchema" => false,
          "payloadSchema" => %{
            "type" => "object",
            "properties" => %{"内容" => %{"type" => "string"}},
            "additionalProperties" => false
          }
        }
      ],
      "nextCursor" => @second_cursor,
      "extra_result" => %{"label" => "原样", "values" => [1, true, nil]}
    }
  end

  defp second_page do
    %{
      "resultType" => "complete",
      "events" => [
        %{
          "name" => "媒体.完成",
          "description" => "完了 🎬",
          "delivery" => ["webhook"],
          "inputSchema" => true,
          "payloadSchema" => false
        },
        %{
          "name" => "job.finished",
          "description" => "Last — 雪",
          "delivery" => ["other", "webhook"],
          "inputSchema" => %{"type" => "object"},
          "payloadSchema" => %{"type" => "object"},
          "extension" => ["汉字", 2]
        }
      ],
      "nextCursor" => "opaque/final+终",
      "extra_result" => ["第二页", %{"kept" => true}]
    }
  end

  defp resource_page do
    %{
      "resultType" => "complete",
      "resources" => [
        %{
          "uri" => "fixture://ordinary/雪",
          "name" => "Ordinary resource",
          "mimeType" => "text/plain"
        }
      ],
      "nextCursor" => "resources/final",
      "extra_result" => %{"kept" => "汉字"}
    }
  end

  defp tool_page do
    %{
      "resultType" => "complete",
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Ordinary echo 雪",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }
  end
end
