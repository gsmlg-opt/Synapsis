defmodule Synapsis.Agent.Tools.ToolInspectionFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{Contract, Session}
  alias Synapsis.Agent.Tools.{Catalog, Discovery, DisplayCatalog, MCP, Profiles, ToolInspection}
  alias Synapsis.Session.Store

  @name "synapsis::tool_describe"
  @source_id "68596b7b-3404-46ec-8d92-4d023158695d"
  @mcp_name "mcp::68596b7b-3404-46ec-8d92-4d023158695d::notes.lookup"
  @function_name "fixture::read_note"
  @custom_name "fixture::expression"
  @instructions String.duplicate("Complete advertised guidance.\n雪 é 🎥 原样。\n", 24)
  @schema %{
    "type" => "object",
    "properties" => %{
      "operation" => %{"type" => "string", "enum" => ["lookup"]},
      "label" => %{"type" => "string", "description" => "Exact label\n雪 é"}
    },
    "required" => ["operation", "label"],
    "additionalProperties" => false
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"],
    "additionalProperties" => false
  }
  @format %{"type" => "grammar", "syntax" => "lark", "definition" => "start: \"雪\"\n"}
  @inspection_schema %{
    "type" => "object",
    "properties" => %{
      "tool_name" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
    },
    "required" => ["tool_name"],
    "additionalProperties" => false
  }

  # This fixture models only the immutable source-owner snapshot API. Managed
  # HTTP discovery/capture has separate coverage in synapsis_mcp's new file.
  defmodule Source do
    use GenServer

    def start_link(tools), do: GenServer.start_link(__MODULE__, tools)

    def init(tools) do
      {:ok,
       %{
         source_id: "68596b7b-3404-46ec-8d92-4d023158695d",
         server_pid: self(),
         generation: 7,
         tools: tools
       }}
    end

    def handle_call(:runtime_snapshot, _from, snapshot), do: {:reply, {:ok, snapshot}, snapshot}
  end

  defmodule Target do
    def execute(%{backend_context: %{counter: counter}}) do
      Agent.update(counter, &(&1 + 1))
      {:ok, %{content: "ordinary target"}}
    end
  end

  defmodule Provider do
    def stream(request, %{observer: observer}) do
      send(observer, {:inspection_provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          after
            10_000 -> raise "inspection fixture provider did not receive its ordinary response"
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  setup do
    assert :ok = Store.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    counter = start_supervised!({Agent, fn -> 0 end})

    identity = %{
      caller: "synapsis:" <> session_id,
      session_id: session_id,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1
    }

    names = [@name, @function_name, @custom_name, @mcp_name, "tool_search"]

    authority = %{
      caller: identity.caller,
      run_id: run_id,
      grants: names,
      tool_revision: 1,
      tool_revisions: Map.put(Map.new(names, &{&1, 1}), @mcp_name, 7)
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    assert :ok =
             Store.put_value(session_id, "permission", %Synapsis.SessionPermission{
               session_id: session_id,
               tool_contract_version: 1
             })

    on_exit(fn -> Store.delete_session(session_id) end)

    native = native_bundle(authority, counter)

    %{
      identity: identity,
      authority: authority,
      session: session,
      binding: binding,
      native: native,
      counter: counter
    }
  end

  test "inspection has one explicit revision-1 descriptor and exact canonical-name schema", ctx do
    context = inspection_context(ctx)
    assert ToolInspection.names() == [@name]
    assert {:ok, [descriptor]} = ToolInspection.descriptors(context)
    assert descriptor.tool_name == @name
    assert descriptor.tool_revision == 1
    assert descriptor.backend == ToolInspection
    assert descriptor.backend_context == context
    assert descriptor.schema == @inspection_schema
    assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
    assert @name in Profiles.supported_names()
    assert Enum.count(Profiles.supported_names(), &(&1 == @name)) == 1

    assert [%{name: @name, category: :workflow, source: "built-in"}] =
             Enum.map(
               Enum.filter(DisplayCatalog.list(), &(&1.name == @name)),
               &Map.take(&1, [:name, :category, :source])
             )

    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  test "ordinary Profiles selections stay default off with eager or explicitly deferred targets",
       ctx do
    source = source_snapshot!()
    original = mcp_descriptor!(ctx, source)

    for deferred <- [[], [@mcp_name]] do
      context =
        profile_context(ctx, [@mcp_name], deferred)
        |> put_in([:agent, :mcp_sources], %{@source_id => source})

      assert {:ok, %{bundle: bundle, snapshot: snapshot, discovery: discovery}} =
               Profiles.build(context, ctx.identity, [], ctx.authority)

      expected_initial = if deferred == [], do: [@mcp_name], else: ["tool_search"]

      expected_issued =
        if deferred == [], do: [@mcp_name], else: [@mcp_name, "tool_search"]

      assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(expected_initial)
      assert Enum.sort(Map.keys(snapshot.issued_descriptors)) == Enum.sort(expected_issued)

      assert snapshot.issued_descriptors[@mcp_name] ===
               expected_mcp_descriptor(original, deferred)

      assert Agent.get(ctx.counter, & &1) == 0
      assert :ok = Discovery.release(discovery)
    end

    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  test "explicit selection freezes the whole selected inventory before either descriptor is deferred",
       ctx do
    source = source_snapshot!()
    original = mcp_descriptor!(ctx, source)
    names = [@name, @mcp_name]

    for deferred <- [[], [@mcp_name], [@name]] do
      context =
        profile_context(ctx, names, deferred)
        |> put_in([:agent, :mcp_sources], %{@source_id => source})

      assert {:ok, %{bundle: bundle, snapshot: snapshot, discovery: discovery}} =
               Profiles.build(context, ctx.identity, [], ctx.authority)

      inspector = snapshot.issued_descriptors[@name]
      assert inspector.backend == ToolInspection
      assert Enum.sort(Map.keys(inspector.backend_context.inventory)) == Enum.sort(names)
      assert inspector.backend_context.inventory[@mcp_name] == mcp_document()
      assert inspector.backend_context.inventory[@name]["schema"] == @inspection_schema
      assert inspector.backend_context.identity == ctx.identity
      assert inspector.backend_context.session_binding == ctx.binding
      assert inspector.backend_context.mcp_sources == %{@mcp_name => source}

      assert snapshot.issued_descriptors[@mcp_name] ===
               expected_mcp_descriptor(original, deferred)

      assert Map.has_key?(bundle.registry.tools, @name) == @name not in deferred
      assert Agent.get(ctx.counter, & &1) == 0
      assert :ok = Discovery.release(discovery)
    end

    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  test "preparation keeps original target descriptors and exact literal MCP/custom public documents",
       ctx do
    source = source_snapshot!()
    scope = Map.take(ctx.identity, [:run_id, :incarnation, :catalog_revision])
    assert {:ok, mcp_descriptors} = MCP.descriptors(Map.put(scope, :source, source))
    assert {:ok, [skeleton]} = ToolInspection.descriptors(inspection_context(ctx))
    names = [@name, @function_name, @custom_name, @mcp_name]

    assert {:ok, original} =
             Catalog.compose([ctx.native], [skeleton | mcp_descriptors], ctx.authority, names)

    assert {:ok, prepared} = ToolInspection.prepare(original, names, ctx.identity, ctx.binding)
    assert prepared.authority === original.authority

    for name <- [@function_name, @custom_name, @mcp_name] do
      assert prepared.registry.tools[name] === original.registry.tools[name]
    end

    inspector = prepared.registry.tools[@name]
    assert Enum.sort(Map.keys(inspector.backend_context.inventory)) == Enum.sort(names)
    assert inspector.backend_context.inventory[@mcp_name] == mcp_document()
    assert inspector.backend_context.inventory[@custom_name] == custom_document()
    assert inspector.backend_context.inventory[@function_name] == function_document()
    assert inspector.backend_context.mcp_sources == %{@mcp_name => source}

    assert original.registry.tools[@mcp_name].codex_output_schema == @output_schema

    assert original.registry.tools[@mcp_name].codex_source == %{
             kind: "mcp",
             source_id: @source_id,
             raw_name: "notes.lookup",
             server_name: "Configured public notes"
           }

    assert original.registry.tools[@mcp_name].backend == MCP
    assert original.registry.tools[@mcp_name].backend_context.source === source
    assert Agent.get(ctx.counter, & &1) == 0

    assert {:ok, without_inspector} =
             Catalog.compose([ctx.native], [], ctx.authority, [@function_name])

    assert {:ok, ^without_inspector} =
             ToolInspection.prepare(
               without_inspector,
               [@function_name],
               ctx.identity,
               ctx.binding
             )

    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  test "native Conversation inspects deferred MCP metadata and itself without target effects",
       ctx do
    source = source_snapshot!()
    original = mcp_descriptor!(ctx, source)
    names = [@name, @mcp_name]

    context =
      profile_context(ctx, names, [@mcp_name])
      |> put_in([:agent, :mcp_sources], %{@source_id => source})

    assert {:ok, %{bundle: bundle, snapshot: snapshot, discovery: discovery}} =
             Profiles.build(context, ctx.identity, [], ctx.authority)

    assert Enum.sort(Map.keys(bundle.registry.tools)) == [@name, "tool_search"]
    frozen = snapshot.issued_descriptors[@name].backend_context.inventory
    assert Enum.sort(Map.keys(frozen)) == Enum.sort(names)
    assert frozen[@mcp_name] == mcp_document()

    assert snapshot.issued_descriptors[@mcp_name] ===
             expected_mcp_descriptor(original, [@mcp_name])

    assert {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: ctx.identity.run_id,
         incarnation: 1,
         session_binding: ctx.binding,
         registry: bundle.registry,
         tools: bundle.tools,
         authority: bundle.authority,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{observer: self()},
         run_timeout: 20_000,
         effect_timeout: 5_000,
         cleanup_timeout: 2_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Inspect selected metadata only")
    assert_receive {:inspection_provider, first_request, provider}, 2_000
    assert Enum.sort(Enum.map(first_request.tools, & &1.name)) == [@name, "tool_search"]

    provider =
      Enum.reduce(
        [{@mcp_name, mcp_document()}, {@name, frozen[@name]}],
        provider,
        fn {target_name, expected}, provider ->
          call_id = "describe-#{target_name}"

          send(provider, {
            :events,
            [
              %{
                type: :tool_call_completed,
                tool_call: %{
                  id: call_id,
                  name: @name,
                  arguments: %{"tool_name" => target_name}
                }
              },
              done()
            ]
          })

          assert_receive {:inspection_provider, request, next_provider}, 5_000
          result = Enum.find(Enum.reverse(request.messages), &(&1[:role] == :tool))
          assert result.tool_call_id == call_id
          assert %{content: content} = result.result
          assert result.result == %{content: content, is_error: false}
          assert is_binary(content)
          assert Jason.decode!(content) == expected
          assert byte_size(content) <= 65_536
          assert Agent.get(ctx.counter, & &1) == 0
          assert Conversation.status(conversation).catalog_revision == 1
          next_provider
        end
      )

    assert Enum.sort(Map.keys(frozen[@name])) ==
             ~w(description input_kind schema tool_name tool_revision)

    send(provider, {:events, [done()]})
    await_completed(conversation, System.monotonic_time(:millisecond) + 3_000)
    assert Agent.get(ctx.counter, & &1) == 0
    assert :ok = Discovery.release(discovery)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  defp inspection_context(ctx) do
    %{identity: ctx.identity, session_binding: ctx.binding, inventory: %{}, mcp_sources: %{}}
  end

  defp profile_context(ctx, names, deferred) do
    %{
      session: %{id: ctx.identity.session_id, config: %{"subagents" => false}},
      agent: %{tools: names, tool_contract_version: 1, deferred_tool_names: deferred},
      tool_session_binding: ctx.binding
    }
  end

  defp mcp_descriptor!(ctx, source) do
    scope = Map.take(ctx.identity, [:run_id, :incarnation, :catalog_revision])
    assert {:ok, descriptors} = MCP.descriptors(Map.put(scope, :source, source))
    Enum.find(descriptors, &(&1.tool_name == @mcp_name))
  end

  defp expected_mcp_descriptor(original, deferred) do
    if @mcp_name in deferred do
      # Native Contract normalization adds only these optional defaults. Every
      # original field, including the executable backend/context, stays exact.
      Map.merge(original, %{
        codex_input_kind: :function,
        codex_format: nil,
        codex_exposure: :direct
      })
    else
      original
    end
  end

  defp native_bundle(authority, counter) do
    attrs = %{
      namespace: "fixture",
      name: "read_note",
      description: "Read a literal note.\n雪 é",
      schema: @schema,
      backend: Target,
      backend_context: %{counter: counter},
      safety: %{read_only: true, retry_safe: true, parallel_safe: true}
    }

    assert {:ok, function} = Contract.new(attrs)

    assert {:ok, custom} =
             Contract.new(
               Map.merge(attrs, %{
                 name: "expression",
                 description: "Literal custom grammar.\n雪",
                 input_kind: :custom,
                 format: @format
               })
             )

    names = [@function_name, @custom_name]

    assert {:ok, bundle} =
             ToolCatalog.admit_batch([Contract.descriptor(function), Contract.descriptor(custom)],
               mode: :strict,
               authority: %{
                 authority
                 | grants: names,
                   tool_revisions: Map.take(authority.tool_revisions, names)
               }
             )

    bundle
  end

  defp source_snapshot! do
    tools = [
      %{
        raw_name: "notes.lookup",
        description: "Exact original MCP description.\n完整 é 🎥",
        parameters: @schema,
        output_schema: @output_schema,
        permission_level: :read,
        source_metadata: %{
          server_name: "Configured public notes",
          instructions_status: "available",
          instructions: @instructions
        }
      },
      %{
        raw_name: "notes.other",
        description: "Another normally advertised tool",
        parameters: %{"type" => "object"},
        permission_level: :read,
        source_metadata: %{
          server_name: "Configured public notes",
          instructions_status: "available",
          instructions: @instructions
        }
      }
    ]

    pid = start_supervised!({Source, tools})
    assert {:ok, source} = Synapsis.MCP.Server.runtime_snapshot(pid)
    source
  end

  defp function_document do
    %{
      "tool_name" => @function_name,
      "tool_revision" => 1,
      "description" => "Read a literal note.\n雪 é",
      "input_kind" => "function",
      "schema" => @schema
    }
  end

  defp custom_document do
    %{
      "tool_name" => @custom_name,
      "tool_revision" => 1,
      "description" => "Literal custom grammar.\n雪",
      "input_kind" => "custom",
      "format" => @format
    }
  end

  defp mcp_document do
    %{
      "tool_name" => @mcp_name,
      "tool_revision" => 7,
      "description" => "Exact original MCP description.\n完整 é 🎥",
      "input_kind" => "function",
      "schema" => @schema,
      "output_schema" => @output_schema,
      "source" => %{
        "kind" => "mcp",
        "source_id" => @source_id,
        "raw_name" => "notes.lookup",
        "server_name" => "Configured public notes",
        "instructions_status" => "available",
        "instructions" => @instructions
      }
    }
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp await_completed(conversation, deadline) do
    case Conversation.status(conversation) do
      %{phase: :terminal, run: %{state: :completed}} ->
        :ok

      status ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(status)
        Process.sleep(10)
        await_completed(conversation, deadline)
    end
  end
end
