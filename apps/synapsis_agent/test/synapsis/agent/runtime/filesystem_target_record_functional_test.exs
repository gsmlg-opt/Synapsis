defmodule Synapsis.Agent.Runtime.FilesystemTargetRecordFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.ToolCatalog
  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Agent.Tools.{Filesystem, Freshness, Profiles}
  alias Synapsis.Session.Store

  @moduletag :tmp_dir
  @names ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls)

  # Production handler harness only. The canonical descriptors are admitted by
  # the real native ToolCatalog, but are fixtures until canonical activation.
  # This does not run Conversation, Policy, a manager, Worker or filesystem IO.
  defmodule TerminalStatusFixture do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call(:status, _from, owner) do
      send(owner, {:terminal_status_fixture, self()})
      {:reply, %{messages: []}, owner}
    end
  end

  setup %{tmp_dir: root} do
    Store.ensure_started()
    session_id = Ecto.UUID.generate()

    # Normal Freshness prerequisite only; no permission decision is evaluated.
    permission = %{
      session_id: session_id,
      tool_contract_version: 1,
      mode: :interactive,
      allow_read: :allow,
      allow_write: :ask,
      allow_execute: :ask,
      allow_destructive: :ask,
      tool_overrides: %{}
    }

    :ok = Store.put_value(session_id, "permission", permission)
    on_exit(fn -> Store.delete_session(session_id) end)
    fixture = fixture(root, session_id, "prepared-root")
    %{fixture: fixture, root: root, session_id: session_id}
  end

  test "reserve seal and fetch expose the immutable record separately from its lifecycle envelope",
       %{fixture: fixture} do
    identity = identity(fixture, "direct-read", "synapsis::read")
    candidate = local_candidate(fixture.root, "report.txt")
    raw = digest(%{"path" => "@report.txt", "optional" => true})
    prepared = digest(%{"path" => "report.txt", "optional" => true})
    state = state(fixture)

    assert {:reply, {:ok, {:new, token}}, reserved} =
             call(state, {:filesystem_target_reserve, identity, fixture.catalog, raw})

    assert is_reference(token)
    reservation = entry(reserved, fixture).prepared_targets[key(identity)]
    assert reservation.state == :reserved
    assert reservation.token === token
    assert reservation.producer_pid === self()
    assert is_reference(reservation.monitor)
    assert reservation.raw_arguments_digest === raw
    assert reservation.correlation === correlation(identity)
    assert reservation.record === nil
    assert entry(reserved, fixture).prepared_target_bytes > 0

    expected = %{
      version: 1,
      key: key(identity),
      correlation: correlation(identity),
      raw_arguments_digest: raw,
      prepared_arguments_digest: prepared,
      original_path: "@report.txt",
      public_path: "report.txt",
      source_path: "report.txt",
      requested_absolute: Path.join(fixture.root, "report.txt"),
      target: {:local, Path.join(fixture.root, "report.txt"), "report.txt"},
      source_prefix: "",
      action: "filesystem.read",
      resource: "filesystem:" <> Path.join(fixture.root, "report.txt")
    }

    assert {:reply, {:ok, ^expected}, sealed} =
             call(
               reserved,
               {:filesystem_target_seal, identity, fixture.catalog, token, candidate, prepared}
             )

    envelope = entry(sealed, fixture).prepared_targets[key(identity)]
    assert envelope.state === :sealed
    assert envelope.record === expected
    assert envelope.token === token
    assert envelope.producer_pid === self()
    assert envelope.monitor === reservation.monitor
    assert envelope.raw_arguments_digest === raw
    assert entry(sealed, fixture).prepared_target_bytes > 0

    assert {:reply, {:ok, ^expected}, ^sealed} =
             call(sealed, {:filesystem_target_fetch, identity, fixture.catalog, prepared})

    # Exact equality above also excludes content, args and lifecycle handles.
    assert Map.keys(expected) |> Enum.sort() ==
             Enum.sort([
               :version,
               :key,
               :correlation,
               :raw_arguments_digest,
               :prepared_arguments_digest,
               :original_path,
               :public_path,
               :source_path,
               :requested_absolute,
               :target,
               :source_prefix,
               :action,
               :resource
             ])
  end

  test "sealed raw and prepared retries and an exact seal retry return the original record",
       %{fixture: fixture} do
    identity = identity(fixture, "retry-read", "synapsis::read")
    candidate = local_candidate(fixture.root, "report.txt")
    raw = digest(%{"path" => "@report.txt"})
    prepared = digest(%{"path" => "report.txt"})
    {sealed, token, record} = seal(state(fixture), fixture, identity, candidate, raw, prepared)

    for fingerprint <- [raw, prepared] do
      assert {:reply, {:ok, {:existing, ^record}}, ^sealed} =
               call(sealed, {:filesystem_target_reserve, identity, fixture.catalog, fingerprint})
    end

    assert {:reply, {:ok, ^record}, ^sealed} =
             call(
               sealed,
               {:filesystem_target_seal, identity, fixture.catalog, token, candidate, prepared}
             )
  end

  test "committed direct self correlation and distinct nested invocation recover their own records",
       %{fixture: fixture} do
    direct = identity(fixture, "direct", "synapsis::read")
    candidate = local_candidate(fixture.root, "report.txt")
    fingerprint = digest(%{"path" => "report.txt"})

    {first, _, direct_record} =
      seal(state(fixture), fixture, direct, candidate, fingerprint, fingerprint)

    assert direct_record.correlation.enclosing_invocation_id === "direct"
    committed = Map.put(direct, :enclosing_invocation_id, "direct")

    assert {:reply, {:ok, ^direct_record}, ^first} =
             call(first, {:filesystem_target_fetch, committed, fixture.catalog, fingerprint})

    nested =
      fixture
      |> identity("nested", "synapsis::read")
      |> Map.put(:enclosing_invocation_id, "native-outer")

    {second, _, nested_record} =
      seal(first, fixture, nested, candidate, fingerprint, fingerprint)

    assert nested_record.key === key(nested)
    assert nested_record.correlation.enclosing_invocation_id === "native-outer"
    assert nested_record.key != direct_record.key
    assert map_size(entry(second, fixture).prepared_targets) == 2

    assert {:reply, {:ok, ^direct_record}, ^second} =
             call(second, {:filesystem_target_fetch, committed, fixture.catalog, fingerprint})

    assert {:reply, {:ok, ^nested_record}, ^second} =
             call(second, {:filesystem_target_fetch, nested, fixture.catalog, fingerprint})
  end

  test "ordinary local write edit omitted list and Workspace records derive their domain metadata",
       %{fixture: fixture} do
    for {name, action} <- [
          {"synapsis::write", "filesystem.write"},
          {"synapsis::edit", "filesystem.edit"}
        ] do
      identity = identity(fixture, name <> "-invocation", name)
      candidate = %{local_candidate(fixture.root, "report.txt") | original_path: "report.txt"}
      fingerprint = digest(%{"path" => "report.txt"})

      {_, _, record} =
        seal(state(fixture), fixture, identity, candidate, fingerprint, fingerprint)

      assert record.action === action
      assert record.resource === "filesystem:" <> Path.join(fixture.root, "report.txt")
    end

    list = identity(fixture, "list", "synapsis::ls")

    omitted = %{
      original_path: :omitted,
      public_path: :omitted,
      source_path: ".",
      requested_absolute: nil,
      target: {:local, fixture.root, "."},
      source_prefix: ""
    }

    fingerprint = digest(%{})
    {_, _, record} = seal(state(fixture), fixture, list, omitted, fingerprint, fingerprint)
    assert record.original_path === :omitted
    assert record.public_path === :omitted
    assert record.source_path === "."
    assert record.target === {:local, fixture.root, "."}
    assert record.action === "filesystem.list"
    assert record.resource === "filesystem:" <> fixture.root

    workspace = identity(fixture, "workspace", "synapsis::read")
    logical = "/shared/report.txt"

    candidate = %{
      original_path: "@synapsis/shared/report.txt",
      public_path: "@synapsis/shared/report.txt",
      source_path: "@synapsis/shared/report.txt",
      requested_absolute: nil,
      target: {:workspace, logical},
      source_prefix: ""
    }

    fingerprint = digest(%{"path" => candidate.public_path})
    {_, _, record} = seal(state(fixture), fixture, workspace, candidate, fingerprint, fingerprint)
    assert record.target === {:workspace, logical}
    assert record.action === "workspace.read"
    assert record.resource === "workspace:" <> logical
  end

  test "a sealed producer normal monitor exit retains the record for later backend fetch",
       %{fixture: fixture} do
    producer = waiting_process()
    identity = identity(fixture, "producer", "synapsis::read")
    candidate = local_candidate(fixture.root, "report.txt")
    fingerprint = digest(%{"path" => "report.txt"})

    {sealed, token, record} =
      seal(state(fixture), fixture, identity, candidate, fingerprint, fingerprint, producer)

    envelope = entry(sealed, fixture).prepared_targets[key(identity)]
    assert envelope.producer_pid === producer

    send(producer, :finish)
    monitor = envelope.monitor
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal} = down, 2_000
    assert {:noreply, settled} = SessionAdapter.handle_info(down, sealed)
    retained = entry(settled, fixture).prepared_targets[key(identity)]
    assert retained.state === :sealed
    assert retained.monitor === nil
    assert retained.producer_pid === producer
    assert retained.token === token
    assert retained.record === record

    assert {:reply, {:ok, ^record}, ^settled} =
             call(settled, {:filesystem_target_fetch, identity, fixture.catalog, fingerprint})
  end

  test "root normal terminal handler clears zero-resource metadata before its asynchronous status job",
       %{fixture: fixture} do
    identity = identity(fixture, "root-complete", "synapsis::read")
    fingerprint = digest(%{"path" => "report.txt"})

    {sealed, _, _} =
      seal(
        state(fixture),
        fixture,
        identity,
        local_candidate(fixture.root, "report.txt"),
        fingerprint,
        fingerprint
      )

    monitor = entry(sealed, fixture).prepared_targets[key(identity)].monitor
    other_key = {"other-run", 1}
    other = %{fixture.entry | prepared_targets_closed?: false}
    root = start_supervised!({TerminalStatusFixture, self()})

    sealed = %{
      sealed
      | root: root,
        busy: true,
        tool_contexts: Map.put(sealed.tool_contexts, other_key, other)
    }

    assert {:noreply, completed} =
             SessionAdapter.handle_info(
               {:agent_runtime, fixture.identity.run_id, %{type: :run_completed}},
               sealed
             )

    assert_closed_or_removed(completed, fixture)
    assert completed.tool_contexts[other_key] === other
    assert Process.demonitor(monitor, [:info]) === false

    # Drain the real handler-created task, but do not claim its fixture status
    # is a native Conversation or feed it through full terminal history logic.
    [{job_ref, {job_pid, job_monitor, {:terminal, %{type: :run_completed}}}}] =
      Map.to_list(completed.jobs)

    assert_receive {:terminal_status_fixture, ^root}, 2_000
    assert_receive {:job_result, ^job_ref, %{messages: [], discovery_cleanup: %{}}}, 2_000
    assert_receive {:DOWN, ^job_monitor, :process, ^job_pid, :normal}, 2_000
  end

  test "child normal settlement clears its metadata independently of absent or retained Discovery work",
       %{fixture: root_fixture, root: root, session_id: session_id} do
    for discovery <- [nil, %{fixture_evidence: :retained}] do
      child_fixture = fixture(root, session_id, "prepared-child-#{is_nil(discovery)}")
      identity = identity(child_fixture, "child-complete", "synapsis::read")
      fingerprint = digest(%{"path" => "report.txt"})

      initial = %{
        state(root_fixture)
        | tool_contexts:
            Map.put(state(root_fixture).tool_contexts, context_key(child_fixture), %{
              child_fixture.entry
              | discovery: discovery
            })
      }

      {sealed, _, _} =
        seal(
          initial,
          child_fixture,
          identity,
          local_candidate(root, "report.txt"),
          fingerprint,
          fingerprint
        )

      monitor = entry(sealed, child_fixture).prepared_targets[key(identity)].monitor
      job_key = make_ref()

      jobs =
        if discovery,
          do: %{job_key => {self(), make_ref(), {:discovery_cleanup, identity.run_id}}},
          else: %{}

      sealed = %{sealed | jobs: jobs}
      root_entry = entry(sealed, root_fixture)

      event = %{
        type: :agent_completed,
        manager_id: "fixture-manager",
        revision: 1,
        agent: %{agent_id: "child", run_id: identity.run_id, status: :completed}
      }

      assert {:noreply, settled} =
               SessionAdapter.handle_info({:codex_collaboration, event}, sealed)

      assert_closed_or_removed(settled, child_fixture)
      assert Process.demonitor(monitor, [:info]) === false
      assert entry(settled, root_fixture) === root_entry
      assert settled.jobs === jobs

      if discovery do
        assert entry(settled, child_fixture).discovery === discovery
        assert entry(settled, child_fixture).snapshot === child_fixture.snapshot
      end
    end
  end

  test "preparation binding returns the exact issued descriptor and selected binding before classification",
       %{fixture: fixture} do
    invocation = identity(fixture, "binding", "synapsis::read")

    assert {:ok, projected} =
             Profiles.project_catalog(invocation, fixture.snapshot, fixture.catalog)

    owner = self()

    classifier = fn invocation ->
      send(owner, {:preparation_classifier_called, invocation})
      {:ok, %{action: "filesystem.read", resource: "filesystem:fixture"}}
    end

    binding = %{projected.selected[invocation.tool_name] | classify: classifier}
    snapshot = %{projected | selected: Map.put(projected.selected, invocation.tool_name, binding)}
    descriptor = fixture.catalog.registry.tools[invocation.tool_name]

    assert {:ok, %{descriptor: ^descriptor, binding: ^binding}} =
             Profiles.preparation_binding(invocation, snapshot)

    refute_received {:preparation_classifier_called, _}
  end

  defp fixture(root, session_id, run_id) do
    identity = %{
      caller: "prepared-fixture",
      session_id: session_id,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1
    }

    context = %{
      root: root,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1,
      workspace: %{role: :session, session_id: session_id},
      path_environment: %{cwd: root, os_home: root, platform: :linux, workspace_root: root}
    }

    descriptors =
      Enum.map(@names, fn name ->
        %{
          tool_name: name,
          tool_revision: 1,
          description: "Prepared-target fixture",
          schema: %{"type" => "object", "properties" => %{}},
          safety: %{read_only: true, retry_safe: true, parallel_safe: true},
          backend: Filesystem,
          backend_context: context
        }
      end)

    authority = %{
      caller: identity.caller,
      run_id: run_id,
      grants: @names,
      tool_revisions: Map.new(@names, &{&1, 1})
    }

    assert {:ok, admitted} =
             ToolCatalog.admit_batch(descriptors, authority: authority, mode: :strict)

    catalog = Map.take(admitted, [:registry, :tools, :authority]) |> Map.put(:revision, 1)

    assert {:ok, evidence} =
             Freshness.capture(session_id, %{provider_ids: [], credential_ids: []})

    snapshot = %{
      scope: identity,
      issued_descriptors: admitted.registry.tools,
      selected: %{},
      known_bindings: %{},
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

    %{root: root, identity: identity, catalog: catalog, snapshot: snapshot, entry: entry}
  end

  defp state(fixture) do
    %{
      owner: self(),
      owner_ref: make_ref(),
      session_id: fixture.identity.session_id,
      adapter: self(),
      epoch: "fixture-epoch",
      tool_contexts: %{context_key(fixture) => fixture.entry},
      discovery_cleanup: %{},
      closing: false,
      error: nil,
      busy: false,
      root: nil,
      run_id: fixture.identity.run_id,
      jobs: %{},
      pending: %{},
      child_sessions: %{},
      browser_resources: %{},
      mcp_resource_runtimes: %{},
      roster: %{agents: [], admissions: []},
      store: %{namespace: Ecto.UUID.generate()}
    }
  end

  defp identity(fixture, invocation_id, name) do
    fixture.identity
    |> Map.drop([:caller, :session_id])
    |> Map.merge(%{
      invocation_id: invocation_id,
      tool_name: name,
      tool_revision: 1,
      turn_id: "turn",
      step_id: "step",
      attempt_id: "attempt",
      tool_call_id: invocation_id <> "-call"
    })
  end

  defp local_candidate(root, path) do
    %{
      original_path: "@" <> path,
      public_path: path,
      source_path: path,
      requested_absolute: Path.join(root, path),
      target: {:local, Path.join(root, path), path},
      source_prefix: ""
    }
  end

  defp correlation(identity) do
    identity
    |> Map.take([:turn_id, :step_id, :attempt_id, :tool_call_id])
    |> Map.put(
      :enclosing_invocation_id,
      identity[:enclosing_invocation_id] || identity.invocation_id
    )
  end

  defp key(identity),
    do:
      {identity.run_id, identity.incarnation, identity.catalog_revision, identity.invocation_id,
       identity.tool_name, identity.tool_revision}

  defp context_key(fixture), do: {fixture.identity.run_id, fixture.identity.incarnation}
  defp entry(state, fixture), do: state.tool_contexts[context_key(fixture)]

  defp call(state, message, producer \\ self()),
    do: SessionAdapter.handle_call(message, {producer, make_ref()}, state)

  defp seal(state, fixture, identity, candidate, raw, prepared, producer \\ self()) do
    assert {:reply, {:ok, {:new, token}}, reserved} =
             call(state, {:filesystem_target_reserve, identity, fixture.catalog, raw}, producer)

    assert {:reply, {:ok, record}, sealed} =
             call(
               reserved,
               {:filesystem_target_seal, identity, fixture.catalog, token, candidate, prepared},
               producer
             )

    {sealed, token, record}
  end

  defp assert_closed_or_removed(state, fixture) do
    case entry(state, fixture) do
      nil ->
        :ok

      entry ->
        assert entry.prepared_targets === %{}
        assert entry.prepared_target_bytes === 0
        assert entry.prepared_targets_closed? === true
    end
  end

  defp waiting_process do
    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end)

    on_exit(fn -> send(pid, :finish) end)
    pid
  end

  defp digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))
end
