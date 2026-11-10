defmodule Synapsis.Agent.Tools.WorkspaceMemoryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{
    Budget,
    Conversation,
    EphemeralStore,
    Error,
    Execution,
    InputSchema,
    ToolCatalog
  }

  alias Synapsis.Agent.Tools.WorkspaceMemory
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof

  @moduletag :tmp_dir
  @search "synapsis::workspace_memory_search"
  @get "synapsis::workspace_memory_get"

  defmodule RecordingBackend do
    def execute(operation) do
      send(operation.backend_context.test_pid, :workspace_memory_dispatched)
      WorkspaceMemory.execute(operation)
    end
  end

  setup %{tmp_dir: root} do
    context = %{root: root, run_id: "run-a", incarnation: 1, catalog_revision: 1}
    %{context: context}
  end

  test "strict native admission preserves names, provider arguments and exact authority", ctx do
    assert {:ok, [search, get] = descriptors} = WorkspaceMemory.descriptors(ctx.context)
    assert Enum.map(descriptors, & &1.tool_name) == [@search, @get]

    for descriptor <- descriptors do
      assert descriptor.backend == WorkspaceMemory
      assert descriptor.backend_context === ctx.context
      assert descriptor.tool_revision === 1
      assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
      assert descriptor.schema["additionalProperties"] == false
    end

    assert search.schema["required"] == ["query"]
    assert Enum.sort(Map.keys(search.schema["properties"])) == ["limit", "query"]
    assert get.schema["required"] == ["path"]
    assert Enum.sort(Map.keys(get.schema["properties"])) == ["from", "lines", "path"]
    assert {:ok, _} = InputSchema.validate(search.schema, %{"query" => "memory", "limit" => 20})

    assert {:ok, _} =
             InputSchema.validate(get.schema, %{"path" => "MEMORY.md", "from" => 2, "lines" => 1})

    assert {:error, %Error{}} =
             InputSchema.validate(search.schema, %{"query" => "q", "root" => "/"})

    assert {:error, %Error{}} =
             InputSchema.validate(get.schema, %{"path" => "MEMORY.md", "lines" => 121})

    assert {:ok, %{accepted: names, tools: tools}} =
             ToolCatalog.admit_batch(descriptors, authority: authority())

    assert names == [@search, @get]
    assert Enum.map(tools, & &1.parameters) == Enum.map(descriptors, & &1.schema)

    for changed <- [
          %{authority() | grants: ["*"]},
          %{authority() | grants: []},
          %{authority() | tool_revisions: %{@search => 2, @get => 1}}
        ] do
      assert {:error, %Error{}} = ToolCatalog.admit_batch(descriptors, authority: changed)
    end
  end

  test "classification binds the workspace and exact canonical file without reading", ctx do
    assert {:ok, %{action: "memory.search", resource: resource}} =
             WorkspaceMemory.classify(ctx.context, operation(ctx, @search, %{"query" => "q"}))

    assert resource == "memory:workspace:#{ctx.context.root}"

    for path <- ["MEMORY.md", "memory/nested/note.md"] do
      assert {:ok, %{action: "memory.read", resource: file_resource}} =
               WorkspaceMemory.classify(ctx.context, operation(ctx, @get, %{"path" => path}))

      assert file_resource == resource <> ":file:" <> path
    end

    assert File.ls!(ctx.context.root) == []
  end

  test "plain nested Markdown search and read return actual one-based citations", ctx do
    put(ctx, "MEMORY.md", "# Memory\nConcord stores turns\n")
    put(ctx, "memory/nested/daily.md", "# Daily\nConcord has snapshots\nfinal\n")
    put(ctx, "README.md", "Concord is unrelated")

    assert {:ok, %{content: text, structured: %{ranking: "lexical", results: results}}} =
             WorkspaceMemory.execute(operation(ctx, @search, %{"query" => "concord"}))

    assert Enum.map(results, &{&1.path, &1.from, &1.to}) == [
             {"MEMORY.md", 2, 2},
             {"memory/nested/daily.md", 2, 2}
           ]

    assert text =~ "MEMORY.md:2"
    assert text =~ "memory/nested/daily.md:2"
    assert text =~ "Concord has snapshots"
    refute text =~ "README.md"

    assert {:ok, %{content: read_text, structured: page}} =
             WorkspaceMemory.execute(
               operation(ctx, @get, %{
                 "path" => "memory/nested/daily.md",
                 "from" => 2,
                 "lines" => 1
               })
             )

    assert page.path == "memory/nested/daily.md"
    assert page.from == 2 and page.to == 2
    assert page.content == "Concord has snapshots\n"
    assert page.truncated and page.next_from == 3
    assert read_text =~ "memory/nested/daily.md:2"
    assert read_text =~ "truncated"
    assert read_text =~ "3"
    assert Jason.encode!(page)
  end

  test "invalid trusted contexts and model authority selectors are rejected", ctx do
    for context <- [
          nil,
          Map.delete(ctx.context, :root),
          Map.put(ctx.context, :project_id, "project-a"),
          %{ctx.context | root: "relative"},
          %{ctx.context | root: ctx.context.root <> "/../other"},
          %{ctx.context | root: <<255>>},
          %{ctx.context | run_id: ""},
          %{ctx.context | incarnation: 0},
          %{ctx.context | catalog_revision: 1.0}
        ] do
      assert {:error, %Error{class: :validation}} = WorkspaceMemory.descriptors(context)
    end

    for key <- ["root", "agent_id", "source", "project_id", "session_id", "ownership"] do
      arguments = %{"query" => "q", key => "foreign"}

      assert {:error, :invalid_input} =
               WorkspaceMemory.classify(ctx.context, operation(ctx, @search, arguments))

      assert {:error, %Error{class: :validation}} =
               WorkspaceMemory.execute(operation(ctx, @search, arguments))
    end

    for arguments <- [
          %{},
          %{"query" => ""},
          %{"query" => <<255>>},
          %{"query" => String.duplicate("é", 1025)},
          %{"query" => "q", "limit" => 0},
          %{"query" => "q", "limit" => 21},
          %{"query" => "q", "limit" => 1.0}
        ] do
      assert {:error, %Error{class: :validation}} =
               WorkspaceMemory.execute(operation(ctx, @search, arguments))
    end

    for path <- [
          "/MEMORY.md",
          "../MEMORY.md",
          "memory/../MEMORY.md",
          "memory//a.md",
          "memory/./a.md",
          "memory\\a.md",
          "memory.md",
          "README.md",
          "memory/a.txt",
          <<255>>
        ] do
      assert {:error, :invalid_input} =
               WorkspaceMemory.classify(ctx.context, operation(ctx, @get, %{"path" => path}))
    end

    for arguments <- [
          %{"path" => "MEMORY.md", "from" => 0},
          %{"path" => "MEMORY.md", "lines" => 121},
          %{"path" => "MEMORY.md", "root" => "/"}
        ] do
      assert {:error, %Error{class: :validation}} =
               WorkspaceMemory.execute(operation(ctx, @get, arguments))
    end
  end

  test "stale revisions and tampered backend context fail before dispatch", ctx do
    op = operation(ctx, @search, %{"query" => "q"})

    for {field, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 1.0,
          tool_revision: 1.0
        ] do
      changed = Map.put(op, field, value)
      assert {:error, :scope_mismatch} = WorkspaceMemory.classify(ctx.context, changed)
      assert {:error, %Error{class: :forbidden}} = WorkspaceMemory.execute(changed)
    end

    tampered = put_in(op, [:backend_context, :root], Path.join(ctx.context.root, "other"))
    assert {:error, :scope_mismatch} = WorkspaceMemory.classify(ctx.context, tampered)

    assert {:error, %Error{class: :validation}} =
             WorkspaceMemory.execute(%{op | tool_name: "memory::recall"})

    assert {:error, %Error{class: :validation}} = WorkspaceMemory.execute(nil)
    assert :ok = WorkspaceMemory.cancel(op)
  end

  test "empty matches, empty pages, missing files and unavailable workspaces stay distinct",
       ctx do
    assert {:ok, %{content: text, structured: %{results: []}}} =
             WorkspaceMemory.execute(operation(ctx, @search, %{"query" => "absent"}))

    assert text =~ "No matching workspace memory"

    put(ctx, "MEMORY.md", "")

    assert {:ok, %{content: empty, structured: %{content: "", from: 1, to: 0}}} =
             WorkspaceMemory.execute(operation(ctx, @get, %{"path" => "MEMORY.md"}))

    assert String.trim(empty) != ""
    refute empty =~ "MEMORY.md:1-0"

    assert {:error, %Error{class: :not_found}} =
             WorkspaceMemory.execute(operation(ctx, @get, %{"path" => "memory/missing.md"}))

    unavailable = put_in(ctx, [:context, :root], Path.join(ctx.context.root, "absent"))

    assert {:error, %Error{class: :unsupported_capability, details: %{code: "unavailable"}}} =
             WorkspaceMemory.execute(operation(unavailable, @search, %{"query" => "q"}))
  end

  test "oversized first lines retain reader partial-line notice and cannot claim continuation",
       ctx do
    put(ctx, "MEMORY.md", String.duplicate("a", 12_001) <> "\nnext line")

    assert {:ok, %{content: text, structured: page}} =
             WorkspaceMemory.execute(operation(ctx, @get, %{"path" => "MEMORY.md"}))

    assert page.partial_line and page.truncated
    assert page.next_from == nil
    assert page.from == 1 and page.to == 1
    assert text =~ page.notice
    assert text =~ "MEMORY.md:1"
    assert text =~ "truncated"
    refute text =~ "next line"
  end

  test "combined encoded text and structured output share one 64KiB budget", ctx do
    put(ctx, "MEMORY.md", String.duplicate("界", 12_001))
    assert {:ok, page} = Synapsis.Memory.read_workspace(ctx.context.root, "MEMORY.md")
    assert byte_size(Jason.encode!(page)) < 65_536

    assert {:error, %Error{class: :budget_exceeded, details: %{code: "output_limit"}}} =
             WorkspaceMemory.execute(operation(ctx, @get, %{"path" => "MEMORY.md"}))
  end

  test "native Execution reads real files and revoked grants create no dispatch or intent", ctx do
    put(ctx, "memory/nested/proof.md", "# Proof\nactual native result\n")
    {:ok, descriptors} = WorkspaceMemory.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority())
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
      operation(ctx, @get, %{"path" => "memory/nested/proof.md", "from" => 2})
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "invocation"})

    options = [
      registry: bundle.registry,
      authority: authority(),
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2_000,
      cleanup_timeout: 500
    ]

    assert {:ok, _,
            %{
              effects: [
                %{
                  structured: %{
                    path: "memory/nested/proof.md",
                    from: 2,
                    content: "actual native result\n"
                  }
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
      Enum.map(descriptors, fn descriptor ->
        %{
          descriptor
          | backend: RecordingBackend,
            backend_context: Map.put(descriptor.backend_context, :test_pid, self())
        }
      end)

    {:ok, spy_bundle} = ToolCatalog.admit_batch(spy, authority: authority())
    {:ok, denied_table} = EphemeralStore.new(1)

    denied =
      options
      |> Keyword.put(:registry, spy_bundle.registry)
      |> Keyword.put(:authority, %{authority() | grants: []})

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               denied_table,
               record,
               %{command: {:tool_invoked, 11, input}},
               denied
             )

    assert :ets.tab2list(denied_table) == []
    refute_receive :workspace_memory_dispatched
  end

  test "native hierarchical run identities remain opaque while scope matching stays exact", ctx do
    put(ctx, "MEMORY.md", "Child memory\n")

    for run_id <- ["/root/researcher:1", "/root/研究者/child:2"] do
      child = put_in(ctx, [:context, :run_id], run_id)
      assert {:ok, _} = WorkspaceMemory.descriptors(child.context)
      op = %{operation(child, @get, %{"path" => "MEMORY.md"}) | run_id: run_id}
      assert {:ok, _} = WorkspaceMemory.classify(child.context, op)
      assert {:ok, _} = WorkspaceMemory.execute(op)

      assert {:error, :scope_mismatch} =
               WorkspaceMemory.classify(child.context, %{op | run_id: "other"})

      assert {:error, %Error{class: :forbidden}} =
               WorkspaceMemory.execute(%{op | run_id: "other"})
    end

    for run_id <- [nil, 0, "", " ", <<255>>, "child\0run", String.duplicate("r", 4097)] do
      child = put_in(ctx, [:context, :run_id], run_id)
      assert {:error, %Error{class: :validation}} = WorkspaceMemory.descriptors(child.context)

      assert {:error, %Error{class: :validation}} =
               WorkspaceMemory.execute(operation(child, @get, %{"path" => "MEMORY.md"}))
    end
  end

  test "native Conversation executes both descriptors with runtime-enriched child context", ctx do
    run_id = "/root/researcher:1"
    ctx = put_in(ctx, [:context, :run_id], run_id)
    put(ctx, "MEMORY.md", "Native Conversation memory\n")
    {:ok, descriptors} = WorkspaceMemory.descriptors(ctx.context)

    {:ok, bundle} =
      ToolCatalog.admit_batch(descriptors,
        mode: :strict,
        authority: Map.put(authority(), :run_id, run_id)
      )

    script = fn request ->
      case Enum.count(request.messages, &(&1.role == :tool)) do
        0 ->
          [Proof.call(@search, %{"query" => "memory"}), Proof.completed("Searching")]

        1 ->
          [
            put_in(Proof.call(@get, %{"path" => "MEMORY.md"}), [:tool_call, :id], "read-call"),
            Proof.completed("Reading")
          ]

        _ ->
          [Proof.completed("Done")]
      end
    end

    options =
      Proof.options(run_id, script,
        registry: bundle.registry,
        tools: bundle.tools,
        authority: bundle.authority,
        schema_admission: :strict,
        work: 10
      )

    pid = start_supervised!({Conversation, options})
    caller = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(caller, pid, "Read native resources")
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 2_000
    assert [search, read] = Enum.filter(Conversation.status(pid).messages, &(&1.role == :tool))
    refute Map.get(search.result, :is_error, false)
    refute Map.get(read.result, :is_error, false)
    assert search.result.structured.results != []
    assert read.result.structured.content == "Native Conversation memory\n"
  end

  test "only documented runtime additions are ignored by execute; trusted classification stays strict",
       ctx do
    put(ctx, "MEMORY.md", "Native Conversation memory\n")
    base = operation(ctx, @get, %{"path" => "MEMORY.md"})

    enriched =
      Map.merge(ctx.context, %{
        interact: fn _ -> :unused end,
        append_feedback: fn _ -> :unused end,
        emit: fn _ -> :unused end,
        stage_catalog: fn _ -> :unused end,
        request_new_context: fn -> :unused end,
        nested_dispatch: fn _ -> :unused end,
        resource_owner_pid: self()
      })

    assert {:ok, _} = WorkspaceMemory.execute(%{base | backend_context: enriched})
    assert {:error, %Error{class: :validation}} = WorkspaceMemory.descriptors(enriched)

    assert {:error, :invalid_context} =
             WorkspaceMemory.classify(enriched, %{base | backend_context: enriched})

    invalid = Map.put(enriched, :project_id, "foreign")

    assert {:error, %Error{class: :validation}} =
             WorkspaceMemory.execute(%{base | backend_context: invalid})
  end

  defp authority do
    %{
      caller: "caller",
      run_id: "run-a",
      grants: [@search, @get],
      tool_revisions: %{@search => 1, @get => 1}
    }
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

  defp put(ctx, path, content) do
    full = Path.join(ctx.context.root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
