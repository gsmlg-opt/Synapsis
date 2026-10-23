defmodule Synapsis.Agent.Tools.MemoryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Budget, EphemeralStore, Error, Execution, ToolCatalog}
  alias Synapsis.Agent.Tools.Memory

  @moduletag :tmp_dir

  defmodule RecordingBackend do
    def execute(operation) do
      send(operation.backend_context.test_pid, :memory_backend_called)
      Memory.execute(operation)
    end
  end

  setup %{tmp_dir: root} do
    context = %{
      project_id: "project-a",
      session_id: "session-a",
      run_id: "run-a",
      incarnation: 1,
      catalog_revision: 1,
      root: root
    }

    {:ok, descriptors} = Memory.descriptors(context)
    %{context: context, descriptors: descriptors}
  end

  test "strict native admission preserves exact names, schema, backend and grants", ctx do
    names = ["synapsis::memory_search", "synapsis::memory_read"]

    authority = %{
      caller: "caller",
      run_id: "run-a",
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    assert {:ok, %{accepted: ^names}} =
             ToolCatalog.admit_batch(ctx.descriptors, authority: authority)

    assert {:error, %Error{class: :forbidden}} =
             ToolCatalog.admit_batch(ctx.descriptors, authority: %{authority | grants: ["*"]})

    for descriptor <- ctx.descriptors do
      assert descriptor.schema["additionalProperties"] == false
      assert descriptor.backend == Memory
      assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
    end
  end

  test "classifies exact project/session resources and rejects model-selected ownership", ctx do
    search = operation(ctx, "synapsis::memory_search", %{"query" => "Concord"})

    assert {:ok, %{action: "memory.search", resource: resource}} =
             Memory.classify(ctx.context, search)

    assert resource == "memory:project:project-a:session:session-a"
    read = operation(ctx, "synapsis::memory_read", %{"memory_id" => "one"})

    assert {:ok,
            %{
              action: "memory.read",
              resource: "memory:project:project-a:session:session-a:record:one"
            }} =
             Memory.classify(ctx.context, read)

    assert {:error, :invalid_input} =
             Memory.classify(
               ctx.context,
               %{search | arguments: %{"query" => "a", "project_id" => "foreign"}}
             )
  end

  test "backend returns structured public results plus nonblank explicit text", ctx do
    dir = Path.join(ctx.context.root, "project/project-a")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "one.md"),
      "---\nid: one\nscope: project\nscope_id: project-a\ntitle: Architecture\ntags: [storage]\nprivate: secret\n---\n\nUse Concord\n"
    )

    assert {:ok, %{content: content, structured: %{record: record}}} =
             Memory.execute(operation(ctx, "synapsis::memory_read", %{"memory_id" => "one"}))

    assert content =~ "Use Concord"
    assert content =~ "one"
    refute content =~ "secret"
    assert record.citation == %{memory_id: "one", scope: "project", scope_id: "project-a"}
  end

  test "scope mismatches fail before reads and source failure stays explicit", ctx do
    op = operation(ctx, "synapsis::memory_search", %{"query" => "a"})

    for field <- [:run_id, :incarnation, :catalog_revision] do
      assert {:error, %Error{class: :forbidden}} = Memory.execute(Map.put(op, field, "foreign"))
    end

    assert {:error, %Error{class: :validation}} =
             Memory.execute(%{op | arguments: %{"query" => "a", "limit" => 21}})

    assert {:error, %Error{class: :not_found}} =
             Memory.execute(operation(ctx, "synapsis::memory_read", %{"memory_id" => "missing"}))

    unavailable = put_in(op, [:backend_context, :root], Path.join(ctx.context.root, "absent"))

    assert {:error, %Error{class: :unsupported_capability, details: %{code: "unavailable"}}} =
             Memory.execute(unavailable)

    assert {:error, %Error{class: :validation}} =
             Memory.descriptors(%{ctx.context | project_id: "../outside"})
  end

  test "native Execution dispatches the real backend and denies revoked grants before source access",
       ctx do
    names = ["synapsis::memory_search", "synapsis::memory_read"]

    authority = %{
      caller: "caller",
      run_id: "run-a",
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    assert {:ok, bundle} = ToolCatalog.admit_batch(ctx.descriptors, authority: authority)
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 2})

    record = %{
      run_id: "run-a",
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

    input =
      operation(ctx, "synapsis::memory_search", %{"query" => "a"})
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "invocation"})

    options = [
      registry: bundle.registry,
      authority: authority,
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2_000,
      cleanup_timeout: 500
    ]

    assert {:ok, _,
            %{
              effects: [
                %{
                  content: "No matching project semantic memory records.",
                  structured: %{results: []}
                }
              ]
            }} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               options
             )

    spy =
      Enum.map(ctx.descriptors, fn descriptor ->
        %{
          descriptor
          | backend: RecordingBackend,
            backend_context: Map.put(descriptor.backend_context, :test_pid, self())
        }
      end)

    {:ok, spy_bundle} = ToolCatalog.admit_batch(spy, authority: authority)
    {:ok, denied_table} = EphemeralStore.new(1)

    denied =
      options
      |> Keyword.put(:registry, spy_bundle.registry)
      |> Keyword.put(:authority, %{authority | grants: []})

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               denied_table,
               record,
               %{command: {:tool_invoked, 11, input}},
               denied
             )

    assert :ets.tab2list(denied_table) == []
    refute_receive :memory_backend_called
  end

  test "combined text and structured output share one fixed byte budget", ctx do
    dir = Path.join(ctx.context.root, "project/project-a")
    File.mkdir_p!(dir)

    for n <- 1..6 do
      File.write!(
        Path.join(dir, "record-#{n}.md"),
        "---\nid: record-#{n}\nscope: project\nscope_id: project-a\ntitle: Title\ntags: []\n---\n" <>
          String.duplicate("match ", 1_400)
      )
    end

    assert {:error, %Error{class: :budget_exceeded, details: %{code: "output_limit"}}} =
             Memory.execute(
               operation(ctx, "synapsis::memory_search", %{"query" => "match", "limit" => 6})
             )
  end

  defp operation(ctx, name, arguments) do
    %{
      tool_name: name,
      tool_revision: 1,
      arguments: arguments,
      run_id: "run-a",
      incarnation: 1,
      catalog_revision: 1,
      backend_context: ctx.context
    }
  end
end
