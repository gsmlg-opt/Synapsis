defmodule Synapsis.Agent.Tools.FilesystemPreparedNativeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Agent.Tools.{Filesystem, Freshness, Policy, Profiles}
  alias Synapsis.Session.Store

  @moduletag :tmp_dir
  @names ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @fixtures Path.expand("../../../fixtures/openclaw/488631c", __DIR__)

  # The real filesystem factory and seeded host state exercise real Policy and
  # SessionAdapter ledger handlers. This is not Worker, durable history/recovery,
  # media or installed-package qualification.
  defmodule Ledger do
    use GenServer

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    def init(observer), do: {:ok, %{observer: observer, adapter: nil, events: []}}

    def handle_call({:seed, adapter}, _from, state),
      do: {:reply, :ok, %{state | adapter: adapter}}

    def handle_call(:inspect, _from, state), do: {:reply, state, state}

    def handle_call(message, from, state) do
      # The actual preparer/effect pid in from must reach the production handler.
      {:reply, result, adapter} = SessionAdapter.handle_call(message, from, state.adapter)
      event = {elem(message, 0), elem(message, 1), result, elem(from, 0)}
      {:reply, result, %{state | adapter: adapter, events: state.events ++ [event]}}
    end

    def handle_info({:DOWN, _, :process, _, _} = down, state) do
      {:noreply, adapter} = SessionAdapter.handle_info(down, state.adapter)
      {:noreply, %{state | adapter: adapter}}
    end
  end

  defmodule Provider do
    def stream(request, %{observer: observer}) do
      send(observer, {:prepared_provider, request, self()})

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

  defmodule ObservedPolicy do
    def prepare_tool(invocation, context) do
      result = Policy.prepare_tool(invocation, context)
      send(context.fixture_observer, {:prepared_hook, invocation, result, self()})

      receive do
        {:release_prepared_hook, id} when id == invocation.invocation_id -> result
      after
        5_000 -> raise "ordinary prepared hook observation was not released"
      end
    end

    defdelegate tool_effect_timeout(invocation, context), to: Policy
  end

  defmodule ObservedStore do
    @behaviour Backplane.AgentRuntime.Store
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore
    defdelegate new(incarnation), to: EphemeralStore
    def load(context, run_id, opts), do: EphemeralStore.load(context.table, run_id, opts)

    def store(context, record, meta),
      do: observe(context, meta, EphemeralStore.store(context.table, record, meta))

    def acknowledge_commit(context, stage, meta),
      do: observe(context, meta, EphemeralStore.acknowledge_commit(context.table, stage, meta))

    defp observe(context, %{command: {:tool_invoked, _, operation}}, {:ok, ack} = result) do
      send(context.observer, {:prepared_intent, operation, ack.revision, self()})

      receive do
        {:release_prepared_intent, id} when id == operation.invocation_id -> result
      after
        5_000 -> raise "ordinary prepared intent observation was not released"
      end
    end

    defp observe(_context, _meta, result), do: result
  end

  # Ordinary controls use real host classification. Nested dispatch is the
  # supported native callback; no replacement filesystem backend is installed.
  defmodule Control do
    def classify(_context, operation),
      do: {:ok, %{action: "fixture.execute", resource: "fixture:" <> operation.tool_name}}

    def execute(%{tool_name: "fixture::echo", arguments: args}), do: {:ok, %{echo: args}}

    def execute(operation) do
      operation.backend_context.nested_dispatch.(%{
        tool_name: "synapsis::read",
        arguments: operation.arguments
      })
    end
  end

  test "Office/XML write repair and serialized plus legacy edits survive native commit", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "edit.txt"), "alpha\nbeta\ngamma\n")
    fixture = open_fixture(root)

    raw_edit = %{
      "path" => "edit.txt",
      "edits" => ~s([{"oldText":"alpha","newText":"beta","metadata":"discard"}]),
      "oldText" => "beta",
      "newText" => "BETA",
      "metadata" => "discard"
    }

    prepared_edit = %{
      "path" => "edit.txt",
      "edits" => [
        %{"oldText" => "alpha", "newText" => "beta"},
        %{"oldText" => "beta", "newText" => "BETA"}
      ]
    }

    raw_write = %{
      "path" => "report.doccodex</arg_value>>",
      "content" => "new\n",
      "metadata" => "kept"
    }

    prepared_write = %{"path" => "report.docx", "content" => "new\n", "metadata" => "kept"}

    begin_calls(fixture, [
      {"write", "synapsis::write", raw_write},
      {"edit", "synapsis::edit", raw_edit}
    ])

    write = admit(fixture, "synapsis::write", raw_write, prepared_write)
    edit = admit(fixture, "synapsis::edit", raw_edit, prepared_edit)
    {request, provider} = next_request()

    write_receipt = fixture_case("edit-plans", "write-create")["result"]

    write_receipt =
      Map.new(write_receipt, fn
        {"patch", patch} -> {"patch", String.replace(patch, "write.txt", "report.docx")}
        pair -> pair
      end)

    assert result(request, "write") ==
             json_value(%{
               content: [%{type: "text", text: "Successfully wrote 4 bytes to report.docx"}],
               details: Map.merge(write_receipt, %{"changed" => true, "created" => true}),
               is_error: false
             })

    edit_plan = fixture_case("edit-plans", "original-snapshot")["result"]

    assert result(request, "edit") ==
             json_value(%{
               content: [%{type: "text", text: "Successfully replaced 2 block(s) in edit.txt."}],
               details: Map.put(edit_plan["receipt"], "changed", true),
               is_error: false
             })

    assert File.read!(Path.join(root, "report.docx")) == "new\n"
    assert File.read!(Path.join(root, "edit.txt")) == edit_plan["content"]

    assert_record(
      fixture,
      write,
      {:local, Path.join(root, "report.docx"), "report.docx"},
      prepared_write
    )

    assert_record(fixture, edit, {:local, Path.join(root, "edit.txt"), "edit.txt"}, prepared_edit)

    assistant =
      Enum.find(request.messages, &(&1[:role] == :assistant and is_list(&1[:tool_calls])))

    assert Enum.find(assistant.tool_calls, &(&1.id == "edit")).arguments == raw_edit
    finish(fixture, provider)
  end

  test "canonical read uses one-based lines and UTF16 cursor with captured source pages", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "lines.txt"), "alpha\nbeta\ngamma\n")
    File.write!(Path.join(root, "unicode.txt"), "A😀中B\n尾\n")
    fixture = open_fixture(root)
    lines = %{"path" => "lines.txt", "offset" => 2, "limit" => 1, "metadata" => "kept"}
    unicode = %{"path" => "unicode.txt", "cursor" => 3, "limit" => 1}

    begin_calls(fixture, [
      {"lines", "synapsis::read", lines},
      {"unicode", "synapsis::read", unicode}
    ])

    first = admit(fixture, "synapsis::read", lines, lines)
    second = admit(fixture, "synapsis::read", unicode, unicode)
    {request, provider} = next_request()

    for {id, vector} <- [{"lines", "one-based-slice"}, {"unicode", "utf16-selected-slice"}] do
      captured = fixture_case("read-pages", vector)["result"]

      assert result(request, id) ==
               json_value(%{
                 content: [%{type: "text", text: captured["text"]}],
                 details: captured["details"],
                 is_error: false
               })
    end

    assert_record(fixture, first, {:local, Path.join(root, "lines.txt"), "lines.txt"}, lines)

    assert_record(
      fixture,
      second,
      {:local, Path.join(root, "unicode.txt"), "unicode.txt"},
      unicode
    )

    finish(fixture, provider)
  end

  test "literal at and captured home names keep their prepared public spelling", %{tmp_dir: root} do
    File.write!(Path.join(root, "@literal.txt"), "literal\n")
    File.mkdir!(Path.join(root, "home"))
    File.write!(Path.join(root, "home/note.txt"), "home\n")
    fixture = open_fixture(root)
    literal = %{"path" => "@literal.txt"}
    prepared = %{"path" => "./@literal.txt"}
    home = %{"path" => "~/note.txt"}

    begin_calls(fixture, [
      {"literal", "synapsis::read", literal},
      {"home", "synapsis::read", home}
    ])

    first = admit(fixture, "synapsis::read", literal, prepared)
    second = admit(fixture, "synapsis::read", home, home)
    {request, provider} = next_request()
    assert result(request, "literal") == text_result("literal\n")
    assert result(request, "home") == text_result("home\n")

    assert_record(
      fixture,
      first,
      {:local, Path.join(root, "@literal.txt"), "@literal.txt"},
      prepared
    )

    assert_record(
      fixture,
      second,
      {:local, Path.join(root, "home/note.txt"), "home/note.txt"},
      home
    )

    finish(fixture, provider)
  end

  test "successful basename fallback stays pinned when exact spelling appears after preparation",
       %{tmp_dir: root} do
    selected = Path.join(root, "Sam’s.txt")
    File.write!(selected, "alpha\nbeta\n")
    fixture = open_fixture(root)
    args = %{"path" => "Sam's.txt"}
    begin_calls(fixture, [{"fallback", "synapsis::read", args}])

    invocation =
      admit(fixture, "synapsis::read", args, args, fn ->
        # The hook has already selected/sealed the normal successful variant.
        File.write!(Path.join(root, "Sam's.txt"), "new exact spelling\n")
      end)

    {request, provider} = next_request()
    prefix = "[Resolved filename: Sam's.txt -> Sam’s.txt.]\n"

    assert result(request, "fallback") == %{
             "content" => [%{"type" => "text", "text" => prefix <> "alpha\nbeta\n"}],
             "details" => %{"kind" => "text", "content" => "alpha\nbeta\n"},
             "is_error" => false
           }

    record = assert_record(fixture, invocation, {:local, selected, "Sam’s.txt"}, args)
    assert record.source_prefix == prefix
    assert record.requested_absolute == Path.join(root, "Sam's.txt")
    assert File.read!(selected) == "alpha\nbeta\n"
    assert File.read!(Path.join(root, "Sam's.txt")) == "new exact spelling\n"
    finish(fixture, provider)
  end

  test "ls preserves omitted and empty path maps and source binary ordering", %{tmp_dir: root} do
    File.write!(Path.join(root, ".hidden"), "hidden")
    File.mkdir!(Path.join(root, "folder"))
    File.write!(Path.join(root, "雪.txt"), "snow")
    fixture = open_fixture(root)

    begin_calls(fixture, [
      {"omitted", "synapsis::ls", %{}},
      {"empty", "synapsis::ls", %{"path" => "", "metadata" => "kept"}}
    ])

    omitted = admit(fixture, "synapsis::ls", %{}, %{})

    empty =
      admit(fixture, "synapsis::ls", %{"path" => "", "metadata" => "kept"}, %{
        "path" => "",
        "metadata" => "kept"
      })

    {request, provider} = next_request()
    text = "\".hidden\"\n\"folder/\"\n\"雪.txt\""

    expected = %{
      "content" => [%{"type" => "text", "text" => text}],
      "details" => %{"content" => text},
      "is_error" => false
    }

    assert result(request, "omitted") == expected
    assert result(request, "empty") == expected
    first = assert_record(fixture, omitted, {:local, root, "."}, %{})

    second =
      assert_record(fixture, empty, {:local, root, "."}, %{"path" => "", "metadata" => "kept"})

    assert first.public_path == :omitted
    assert second.public_path == ""
    assert first.source_path == "." and second.source_path == "."
    finish(fixture, provider)
  end

  test "physical Workspace write and read use the captured root and logical resource", %{
    tmp_dir: root
  } do
    workspace_root = Path.join(root, "captured-workspace")
    File.mkdir!(workspace_root)
    fixture = open_fixture(root, workspace_root: workspace_root)
    path = "@synapsis/shared/fixture.txt"
    write_args = %{"path" => path, "content" => "new\n"}
    read_args = %{"path" => path}

    begin_calls(fixture, [
      {"write", "synapsis::write", write_args},
      {"read", "synapsis::read", read_args}
    ])

    write = admit(fixture, "synapsis::write", write_args, write_args)
    read = admit(fixture, "synapsis::read", read_args, read_args)
    {request, provider} = next_request()
    receipt = fixture_case("edit-plans", "write-create")["result"]
    receipt = Map.update!(receipt, "patch", &String.replace(&1, "write.txt", path))

    assert result(request, "write") ==
             json_value(%{
               content: [%{type: "text", text: "Successfully wrote 4 bytes to " <> path}],
               details: Map.merge(receipt, %{"changed" => true, "created" => true}),
               is_error: false
             })

    assert result(request, "read") == text_result("new\n")
    assert File.read!(Path.join(workspace_root, "shared/fixture.txt")) == "new\n"

    for {invocation, args, action} <- [
          {write, write_args, "workspace.write"},
          {read, read_args, "workspace.read"}
        ] do
      record = assert_record(fixture, invocation, {:workspace, "/shared/fixture.txt"}, args)
      assert record.action == action
      assert record.resource == "workspace:/shared/fixture.txt"
      assert record.source_path == path
    end

    finish(fixture, provider)
  end

  test "supported native nested read has its own prepared identity and unrelated input is unchanged",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "nested.txt"), "nested source\n")
    fixture = open_fixture(root)
    args = %{"path" => "nested.txt"}
    echo = %{"path" => "report.doccodex</arg_value>>", "edits" => "literal control"}
    begin_calls(fixture, [{"outer", "fixture::outer", args}, {"echo", "fixture::echo", echo}])
    outer = admit(fixture, "fixture::outer", args, args)
    nested = admit(fixture, "synapsis::read", args, args)
    assert nested.invocation_id != outer.invocation_id
    assert nested.enclosing_invocation_id == outer.invocation_id

    assert Map.take(nested, [:turn_id, :step_id, :attempt_id]) ==
             Map.take(outer, [:turn_id, :step_id, :attempt_id])

    control = admit(fixture, "fixture::echo", echo, echo)
    {request, provider} = next_request()
    assert result(request, "outer") == text_result("nested source\n")
    assert result(request, "echo") == %{"echo" => echo, "is_error" => false}

    record =
      assert_record(fixture, nested, {:local, Path.join(root, "nested.txt"), "nested.txt"}, args)

    assert record.correlation.enclosing_invocation_id == outer.invocation_id
    assert control.enclosing_invocation_id == control.invocation_id
    state = GenServer.call(fixture.ledger, :inspect)
    entries = state.adapter.tool_contexts[{fixture.identity.run_id, 1}].prepared_targets
    assert map_size(entries) == 1
    finish(fixture, provider)
  end

  defp open_fixture(root, opts \\ []) do
    Store.ensure_started()
    session_id = Ecto.UUID.generate()

    identity = %{
      caller: "prepared-native-fixture",
      session_id: session_id,
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      catalog_revision: 1
    }

    permission = %{
      session_id: session_id,
      tool_contract_version: 1,
      mode: :autonomous,
      allow_read: :allow,
      allow_write: :allow,
      allow_execute: :allow,
      allow_destructive: :allow,
      tool_overrides: %{}
    }

    :ok = Store.put_value(session_id, "permission", permission)
    on_exit(fn -> Store.delete_session(session_id) end)
    ledger = start_supervised!({Ledger, self()})

    callbacks = %{
      reserve: fn invocation, catalog, digest ->
        GenServer.call(ledger, {:filesystem_target_reserve, invocation, catalog, digest})
      end,
      seal: fn invocation, catalog, token, candidate, digest ->
        GenServer.call(
          ledger,
          {:filesystem_target_seal, invocation, catalog, token, candidate, digest}
        )
      end,
      fetch: fn invocation, catalog, digest ->
        GenServer.call(ledger, {:filesystem_target_fetch, invocation, catalog, digest})
      end,
      abandon: fn invocation, catalog, token ->
        GenServer.call(ledger, {:filesystem_target_abandon, invocation, catalog, token})
      end
    }

    context = %{
      root: root,
      run_id: identity.run_id,
      incarnation: 1,
      catalog_revision: 1,
      workspace: %{role: :user, session_id: session_id},
      path_environment: %{
        cwd: root,
        os_home: Path.join(root, "home"),
        platform: :linux,
        workspace_root: Keyword.get(opts, :workspace_root, root)
      },
      prepared_target_resolver: callbacks.fetch,
      execution_options: [
        node_executable: @node,
        model_budget: nil,
        model_has_vision: true,
        auto_resize_images: true
      ]
    }

    assert {:ok, filesystem_descriptors} = Filesystem.descriptors(context)

    descriptors =
      filesystem_descriptors ++
        Enum.map(~w(fixture::outer fixture::echo), &descriptor(&1, Control, %{}))

    names = Enum.map(descriptors, & &1.tool_name)

    authority = %{
      caller: identity.caller,
      run_id: identity.run_id,
      grants: names,
      tool_revision: 1,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    assert {:ok, admitted} =
             ToolCatalog.admit_batch(descriptors, authority: authority, mode: :strict)

    catalog = admitted |> Map.take([:registry, :tools, :authority]) |> Map.put(:revision, 1)

    assert {:ok, evidence} =
             Freshness.capture(session_id, %{provider_ids: [], credential_ids: []})

    levels =
      Map.new(names, fn name ->
        {name, if(name in ~w(synapsis::write synapsis::edit), do: :write, else: :read)}
      end)

    snapshot = %{
      scope: Map.put(identity, :permission_fingerprint, evidence.permission_fingerprint),
      permission: permission,
      issued_descriptors: admitted.registry.tools,
      selected: %{},
      known_bindings: %{},
      permission_levels: levels,
      evidence: evidence,
      skill_snapshot: nil
    }

    entry = %{
      snapshot: snapshot,
      discovery: nil,
      prepared_targets: %{},
      prepared_target_bytes: 0,
      prepared_targets_closed?: false
    }

    adapter = %{
      owner: self(),
      owner_ref: make_ref(),
      session_id: session_id,
      adapter: ledger,
      epoch: "fixture",
      tool_contexts: %{{identity.run_id, 1} => entry},
      discovery_cleanup: %{},
      closing: false,
      error: nil,
      busy: false,
      root: nil,
      run_id: identity.run_id,
      jobs: %{},
      pending: %{},
      child_sessions: %{},
      browser_resources: %{},
      mcp_resource_runtimes: %{},
      roster: %{agents: [], admissions: []},
      store: %{namespace: Ecto.UUID.generate()}
    }

    assert :ok = GenServer.call(ledger, {:seed, adapter})
    resolver = fn invocation, pinned -> Profiles.project_catalog(invocation, snapshot, pinned) end
    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)
    assert {:ok, table} = EphemeralStore.new(1)
    native_store = %{table: table, observer: self()}

    conversation =
      start_supervised!(
        {Conversation,
         run_id: identity.run_id,
         incarnation: 1,
         session_binding: binding,
         registry: catalog.registry,
         tools: catalog.tools,
         authority: catalog.authority,
         store: ObservedStore,
         context: native_store,
         provider: Provider,
         provider_context: %{observer: self()},
         hooks: ObservedPolicy,
         host_context: %{
           tool_context_resolver: resolver,
           filesystem_preparation: callbacks,
           fixture_observer: self()
         },
         schema_admission: :strict,
         work: 16,
         run_timeout: 30_000,
         effect_timeout: 10_000,
         commit_timeout: 5_000,
         cleanup_timeout: 5_000}
      )

    %{
      root: root,
      identity: identity,
      ledger: ledger,
      catalog: catalog,
      conversation: conversation,
      session: session,
      store: native_store
    }
  end

  defp descriptor(name, backend, context) do
    %{
      tool_name: name,
      tool_revision: 1,
      description: "Isolated prepared native fixture",
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
      safety: %{
        read_only: name not in ~w(synapsis::write synapsis::edit),
        retry_safe: false,
        parallel_safe: false
      },
      backend: backend,
      backend_context: context
    }
  end

  defp begin_calls(fixture, calls) do
    assert {:ok, _} =
             Conversation.prompt(fixture.conversation, "perform ordinary fixture operations")

    assert_receive {:prepared_provider, request, provider}, 5_000

    assert Enum.sort(Enum.map(request.tools, & &1.name)) ==
             Enum.sort(Map.keys(fixture.catalog.registry.tools))

    events =
      Enum.map(calls, fn {id, name, args} ->
        %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: args}}
      end)

    terminal = %{
      type: :response_completed,
      message: %{
        role: :assistant,
        content: "perform fixture operations",
        tool_calls:
          Enum.map(calls, fn {id, name, args} -> %{id: id, name: name, arguments: args} end)
      }
    }

    send(provider, {:events, events ++ [terminal]})
  end

  defp admit(fixture, name, raw, prepared, after_preparation \\ fn -> :ok end) do
    assert_receive {:prepared_hook, invocation, hook_result, hook_worker}, 5_000
    assert invocation.tool_name == name
    assert invocation.arguments == raw
    assert hook_result == if(name in @names, do: {:allow, prepared}, else: :allow)
    after_preparation.()
    send(hook_worker, {:release_prepared_hook, invocation.invocation_id})
    assert_receive {:prepared_intent, operation, revision, writer}, 5_000
    assert operation.invocation_id == invocation.invocation_id
    assert operation.arguments == prepared
    assert operation.tool_name == name
    assert operation.run_id == fixture.identity.run_id
    assert operation.catalog_revision == 1
    assert {:ok, aggregate} = EphemeralStore.load(fixture.store.table, fixture.identity.run_id)
    assert aggregate.revision == revision
    intent = aggregate.run.execution_intents["tool:" <> operation.invocation_id]
    assert intent.status == :started
    # Native canonical command input adds this envelope around the exact intent.
    # The stored intent is the embedded value, not the enriched command input.
    assert intent == operation.execution_intent
    assert intent.type == :tool
    assert intent.reservation.reservation_id == "tool:" <> operation.invocation_id
    assert intent.reservation.status == :reserved

    assert intent.operation ==
             Map.drop(operation, [:execution_intent, :execution_budget, :execution_deadline])

    assert intent.operation.arguments == prepared
    assert aggregate.run.tool_results[operation.invocation_id] == nil
    send(writer, {:release_prepared_intent, operation.invocation_id})
    intent.operation
  end

  defp assert_record(fixture, invocation, target, prepared) do
    state = GenServer.call(fixture.ledger, :inspect)

    key =
      {invocation.run_id, invocation.incarnation, invocation.catalog_revision,
       invocation.invocation_id, invocation.tool_name, invocation.tool_revision}

    envelope = state.adapter.tool_contexts[{invocation.run_id, 1}].prepared_targets[key]
    assert envelope.state == :sealed
    record = envelope.record
    assert record.target == target

    assert record.prepared_arguments_digest ==
             :crypto.hash(:sha256, :erlang.term_to_binary(prepared, [:deterministic]))

    events =
      Enum.filter(state.events, fn {_, identity, _, _} ->
        identity.invocation_id == invocation.invocation_id
      end)

    assert Enum.count(events, &(elem(&1, 0) == :filesystem_target_reserve)) == 1
    assert Enum.count(events, &(elem(&1, 0) == :filesystem_target_seal)) == 1
    fetches = Enum.filter(events, &(elem(&1, 0) == :filesystem_target_fetch))
    assert length(fetches) >= 3
    assert Enum.all?(fetches, &(elem(&1, 2) == {:ok, record}))
    assert Enum.count(fetches, &(elem(&1, 3) == envelope.producer_pid)) >= 2
    assert Enum.any?(fetches, &(elem(&1, 3) != envelope.producer_pid))
    assert record.correlation.enclosing_invocation_id == invocation.enclosing_invocation_id
    record
  end

  defp next_request do
    assert_receive {:prepared_provider, request, provider}, 10_000
    {request, provider}
  end

  defp finish(fixture, provider) do
    send(provider, {:events, [done("ordinary fixture complete")]})
    status = await_completed(fixture.conversation, System.monotonic_time(:millisecond) + 5_000)
    for {_id, intent} <- status.run.execution_intents, do: assert(intent.status == :consumed)
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)
  end

  defp await_completed(conversation, deadline) do
    case Conversation.status(conversation) do
      %{phase: :terminal, run: %{state: :completed}, resource_cleanup: :confirmed} = status ->
        status

      status ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(status)
        Process.sleep(5)
        await_completed(conversation, deadline)
    end
  end

  defp fixture_case(file, id) do
    File.read!(Path.join(@fixtures, file <> ".json"))
    |> Jason.decode!()
    |> Map.fetch!("cases")
    |> Enum.find(&(&1["id"] == id))
  end

  defp result(request, call_id),
    do:
      request.messages
      |> Enum.find(&(&1[:role] == :tool and &1[:tool_call_id] == call_id))
      |> Map.fetch!(:result)
      |> json_value()

  defp text_result(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "details" => %{"kind" => "text", "content" => text},
      "is_error" => false
    }

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp done(text), do: %{type: :response_completed, message: %{role: :assistant, content: text}}
end
