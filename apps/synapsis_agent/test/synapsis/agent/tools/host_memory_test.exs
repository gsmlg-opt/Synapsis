defmodule Synapsis.Agent.Tools.HostMemoryTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Budget, EphemeralStore, Error, Execution, ToolCatalog}
  alias Synapsis.Agent.Tools.HostMemory
  alias Synapsis.Config.Store
  alias Synapsis.Memory.Settings

  @record_id "b9a3299b-29da-4e7e-bc8b-c1d4f98a70e1"

  setup do
    server = Gaoxy.Test.open()
    previous = Store.get(:memory, "default")

    on_exit(fn ->
      case previous do
        {:ok, entry} -> Store.put(:memory, entry)
        {:error, :not_found} -> Store.delete(:memory, "default")
      end
    end)

    context = %{
      source: %{
        id: "backplane-host",
        endpoint: String.trim_trailing(Gaoxy.Test.url(server), "/"),
        agent_id: "synapsis"
      },
      run_id: "run-a",
      incarnation: 1,
      catalog_revision: 1
    }

    ctx = %{server: server, context: context}
    configure(ctx)
    ctx
  end

  test "hierarchical native run identities remain opaque during enriched effect execution", ctx do
    context = %{ctx.context | run_id: "persisted-session/root/child"}
    ctx = %{ctx | context: context}
    assert {:ok, descriptors} = HostMemory.descriptors(context)
    assert Enum.all?(descriptors, &(&1.backend_context.run_id == context.run_id))
    expect(ctx, [])
    op = %{operation(ctx) | run_id: context.run_id}

    enriched =
      Map.merge(context, %{
        interact: fn _ -> flunk("must not invoke native callback") end,
        resource_owner_pid: self()
      })

    assert {:ok, %{structured: %{hits: []}}} =
             HostMemory.execute(%{op | backend_context: enriched})

    assert {:error, %Error{class: :forbidden}} =
             HostMemory.execute(%{op | run_id: "foreign/root/child"})

    assert {:error, %Error{class: :validation}} =
             HostMemory.execute(%{op | backend_context: Map.put(context, :unexpected, self())})
  end

  test "upstream recall and get descriptors require exact grants and revisions", ctx do
    assert {:ok, [descriptor, _get] = descriptors} = HostMemory.descriptors(ctx.context)
    assert descriptor.tool_name == "memory::recall"
    assert descriptor.backend == HostMemory
    assert descriptor.backend_context == ctx.context
    assert descriptor.tool_revision == 1
    assert descriptor.schema["additionalProperties"] == false
    assert descriptor.schema["required"] == ["query"]
    assert Map.keys(descriptor.schema["properties"]) |> Enum.sort() == ["limit", "query"]
    assert descriptor.safety == %{read_only: true, retry_safe: false, parallel_safe: true}
    assert descriptor.description =~ "host"
    assert descriptor.description =~ "offline"
    assert descriptor.description =~ "project"

    assert {:ok, %{accepted: ["memory::recall", "memory::get"]}} =
             ToolCatalog.admit_batch(descriptors, authority: authority())

    for changed <- [
          %{authority() | grants: ["*"]},
          %{authority() | grants: []},
          %{authority() | grants: ["memory::recall"]},
          %{authority() | tool_revisions: %{"memory::recall" => 1}},
          %{authority() | tool_revisions: %{"memory::recall" => 2, "memory::get" => 1}},
          %{authority() | tool_revisions: %{"memory::recall" => 1, "memory::get" => 2}}
        ] do
      assert {:error, %Error{}} = ToolCatalog.admit_batch(descriptors, authority: changed)
    end
  end

  test "get advertises only a canonical record id and classifies its exact resource", ctx do
    assert {:ok, [_recall, descriptor]} = HostMemory.descriptors(ctx.context)
    assert descriptor.tool_name == "memory::get"
    assert descriptor.backend == HostMemory
    assert descriptor.backend_context == ctx.context
    assert descriptor.tool_revision == 1
    assert descriptor.schema["required"] == ["id"]
    assert Map.keys(descriptor.schema["properties"]) == ["id"]
    assert descriptor.schema["additionalProperties"] == false
    assert descriptor.safety == %{read_only: true, retry_safe: false, parallel_safe: true}

    assert {:ok, %{action: "memory.read", resource: resource}} =
             HostMemory.classify(ctx.context, get_operation(ctx))

    assert resource ==
             "memory:host:backplane-host:#{ctx.context.source.endpoint}:partition:host_default:record:#{@record_id}"

    changed = put_in(ctx.context, [:source, :agent_id], "other-route")

    assert {:ok, %{resource: ^resource}} =
             HostMemory.classify(changed, %{get_operation(ctx) | backend_context: changed})

    other = put_in(get_operation(ctx), [:arguments, "id"], "6e2c8dac-211b-44b0-8878-41a5f319c708")
    assert {:ok, %{resource: other_resource}} = HostMemory.classify(ctx.context, other)
    refute other_resource == resource
  end

  test "get rejects noncanonical ids, selectors and stale bindings before HTTP", ctx do
    before = Gaoxy.Test.requests(ctx.server)

    for arguments <- [
          %{},
          %{"id" => "record"},
          %{"id" => String.upcase(@record_id)},
          %{"id" => String.replace(@record_id, "-", "")},
          %{"id" => nil},
          %{"id" => @record_id, "query" => "Concord"},
          %{"id" => @record_id, "limit" => 1},
          %{"id" => @record_id, "project" => "project-a"},
          %{"id" => @record_id, "source" => %{"cwd" => "/tmp"}},
          %{"id" => @record_id, "memory_access_id" => @record_id},
          %{"id" => @record_id, "agent_id" => "other-route"}
        ] do
      assert {:error, %Error{class: :validation, details: %{code: "invalid_input"}}} =
               HostMemory.execute(%{get_operation(ctx) | arguments: arguments})
    end

    for field <- [:run_id, :incarnation, :catalog_revision, :tool_revision] do
      assert {:error, %Error{class: :forbidden, details: %{code: "scope_mismatch"}}} =
               HostMemory.execute(Map.put(get_operation(ctx), field, "stale"))
    end

    changed = put_in(get_operation(ctx), [:backend_context, :source, :id], "other")
    assert {:error, :scope_mismatch} = HostMemory.classify(ctx.context, changed)
    assert Gaoxy.Test.requests(ctx.server) == before
  end

  test "get returns the canonical record with honest state and source citation", ctx do
    expect_get(ctx)
    assert {:ok, %{content: text, structured: result}} = HostMemory.execute(get_operation(ctx))
    assert text =~ "online"
    assert text =~ "canonical"
    assert text =~ "Exact canonical content"
    assert text =~ "record #{@record_id}"
    assert text =~ ctx.context.source.endpoint
    refute text =~ "pending_operations="
    refute text =~ "No matching"
    assert result.mode == "online"
    assert result.authority == "canonical"
    assert result.consistency == "canonical"
    assert result.stale == false
    assert result.history_available == true
    refute Map.has_key?(result, :pending_operations)
    refute Map.has_key?(result, :hits)
    assert result.record.memory_id == @record_id
    assert result.record.canonical_id == @record_id

    assert result.record.citation == %{
             source_id: "backplane-host",
             endpoint: ctx.context.source.endpoint,
             memory_id: @record_id
           }

    assert Jason.encode!(result)
  end

  test "get honors settings revocation and exact source changes before HTTP", ctx do
    assert {:ok, [_recall, get]} = HostMemory.descriptors(ctx.context)
    before = Gaoxy.Test.requests(ctx.server)
    configure(ctx, false)

    assert {:error, %Error{class: :forbidden, details: %{code: "disabled"}}} =
             get.backend.execute(get_operation(ctx))

    for {field, value} <- [endpoint: "http://127.0.0.1:4222", agent_id: "other-route"] do
      configure(put_in(ctx, [:context, :source, field], value))

      assert {:error, %Error{class: :forbidden, details: %{code: "source_changed"}}} =
               get.backend.execute(get_operation(ctx))
    end

    assert Gaoxy.Test.requests(ctx.server) == before
  end

  for {code, class} <- [
        {"not_found", :validation},
        {"canonical_unavailable", :unsupported_capability},
        {"unsupported_operation", :unsupported_capability}
      ] do
    @error_case {code, class}
    test "get keeps #{code} explicit without fallback", ctx do
      {code, class} = @error_case

      Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/get", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => false, "error" => code}))
      end)

      assert {:error, %Error{class: ^class, details: %{code: ^code}} = error} =
               HostMemory.execute(get_operation(ctx))

      refute inspect(error) =~ "Exact canonical content"
      assert length(Gaoxy.Test.requests(ctx.server).entries) == 1
    end
  end

  test "get enforces the combined native text and structured budget", ctx do
    expect_get(ctx, String.duplicate("x", 34_000))

    assert {:error, %Error{class: :budget_exceeded, details: %{code: "output_limit"}}} =
             HostMemory.execute(get_operation(ctx))
  end

  test "classifies host default partition identity including endpoint, never routing agent or project",
       ctx do
    assert {:ok, %{action: "memory.read", resource: resource}} =
             HostMemory.classify(ctx.context, operation(ctx))

    assert resource =~ "backplane-host"
    assert resource =~ ctx.context.source.endpoint
    assert resource =~ "host_default"
    refute resource =~ "synapsis"
    changed = put_in(ctx.context, [:source, :agent_id], "other-route")

    assert {:ok, %{resource: ^resource}} =
             HostMemory.classify(changed, %{operation(ctx) | backend_context: changed})

    other = put_in(ctx.context, [:source, :endpoint], "http://127.0.0.1:4222")

    assert {:ok, %{resource: other_resource}} =
             HostMemory.classify(other, %{operation(ctx) | backend_context: other})

    refute other_resource == resource

    configure(ctx, false)
    assert {:ok, %{resource: ^resource}} = HostMemory.classify(ctx.context, operation(ctx))
  end

  test "disabled host memory advertises no descriptors and rejects execution before HTTP", ctx do
    configure(ctx, false)
    before = Gaoxy.Test.requests(ctx.server)
    assert {:ok, []} = HostMemory.descriptors(ctx.context)

    assert {:error, %Error{class: :forbidden, details: %{code: "disabled"}}} =
             HostMemory.execute(operation(ctx))

    assert Gaoxy.Test.requests(ctx.server) == before
  end

  test "disabling host memory invalidates an already admitted descriptor", ctx do
    assert {:ok, [descriptor, _get] = descriptors} = HostMemory.descriptors(ctx.context)

    assert {:ok, %{accepted: ["memory::recall", "memory::get"]}} =
             ToolCatalog.admit_batch(descriptors, authority: authority())

    configure(ctx, false)
    before = Gaoxy.Test.requests(ctx.server)
    op = %{operation(ctx) | backend_context: descriptor.backend_context}

    assert {:error, %Error{class: :forbidden, details: %{code: "disabled"}}} =
             descriptor.backend.execute(op)

    assert Gaoxy.Test.requests(ctx.server) == before
  end

  test "changed endpoint or routing agent rejects a stale source before HTTP", ctx do
    assert {:ok, [_recall, _get]} = HostMemory.descriptors(ctx.context)
    before = Gaoxy.Test.requests(ctx.server)

    for {field, value} <- [endpoint: "http://127.0.0.1:4222", agent_id: "other-route"] do
      changed = put_in(ctx, [:context, :source, field], value)
      configure(changed)

      assert {:error, %Error{class: :forbidden, details: %{code: "source_changed"}}} =
               HostMemory.descriptors(ctx.context)

      assert {:error, %Error{class: :forbidden, details: %{code: "source_changed"}}} =
               HostMemory.execute(operation(ctx))

      assert Gaoxy.Test.requests(ctx.server) == before
    end
  end

  test "rejects invalid contexts, stale binding and unauthorized arguments before HTTP", ctx do
    for context <- [
          nil,
          Map.delete(ctx.context, :source),
          Map.put(ctx.context, :project_id, "project"),
          %{ctx.context | incarnation: 0},
          put_in(ctx.context, [:source, :endpoint], "http://localhost:4222")
        ] do
      assert {:error, %Error{class: :validation}} = HostMemory.descriptors(context)
    end

    for field <- [:run_id, :incarnation, :catalog_revision, :tool_revision] do
      op = Map.put(operation(ctx), field, "stale")
      assert {:error, :scope_mismatch} = HostMemory.classify(ctx.context, op)

      assert {:error, %Error{class: :forbidden, details: %{code: "scope_mismatch"}}} =
               HostMemory.execute(op)
    end

    for arguments <- [
          %{"query" => "q", "project_id" => "p"},
          %{"query" => "q", "scope" => "shared"},
          %{"query" => "q", "memory_access_id" => "x"},
          %{"query" => "q", "agent_id" => "x"},
          %{"query" => "q", "limit" => 21},
          %{"query" => ""},
          %{"memory_id" => "one"},
          %{"query" => String.duplicate("é", 1025)}
        ] do
      assert {:error, %Error{class: :validation}} =
               HostMemory.execute(%{operation(ctx) | arguments: arguments})
    end

    different = put_in(operation(ctx), [:backend_context, :source, :id], "other")
    assert {:error, :scope_mismatch} = HostMemory.classify(ctx.context, different)

    assert {:error, %Error{class: :validation}} =
             HostMemory.execute(%{operation(ctx) | tool_name: "memory::get"})
  end

  test "returns portable public result and explicit host state with honest record citations",
       ctx do
    expect(ctx, [%{"id" => "one", "content" => "Concord content"}])
    assert {:ok, %{content: text, structured: result}} = HostMemory.execute(operation(ctx))
    assert text =~ "online"
    assert text =~ "canonical"
    assert text =~ "Concord content"
    assert text =~ "backplane-host"
    assert text =~ "one"
    refute text =~ "project-a"
    assert [%{memory_id: "one", citation: %{source_id: "backplane-host"}}] = result.hits
    assert Jason.encode!(result)
  end

  test "offline canonical-only mirror IDs survive native text and portable citations", ctx do
    mirror = %{
      "canonical_id" => "mirror-record",
      "memory_type" => "semantic",
      "content" => "offline insight",
      "content_hash" => "sha256:" <> String.duplicate("a", 64),
      "confidence" => 0.8,
      "lifecycle_state" => "disputed",
      "tags" => [],
      "metadata" => %{},
      "source_refs" => [],
      "server_revision" => 7,
      "edge_expires_at" => nil
    }

    result = %{
      "mode" => "offline",
      "authority" => "canonical",
      "consistency" => "bounded_stale",
      "stale" => true,
      "history_available" => true,
      "pending_operations" => 0,
      "hits" => [mirror],
      "results" => [mirror],
      "items" => [mirror],
      "source" => "edge_mirror",
      "as_of" => "2026-10-23T12:00:00Z",
      "partition_revision" => 7,
      "last_sync_age_seconds" => 12,
      "overlay_truncated" => false,
      "acknowledged_operations" => 0
    }

    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/synapsis/call/recall",
      &Plug.Conn.resp(&1, 200, Jason.encode!(%{"ok" => true, "result" => result}))
    )

    assert {:ok, %{content: text, structured: %{hits: [hit]} = public}} =
             HostMemory.execute(operation(ctx))

    assert text =~ "offline"
    assert text =~ "bounded_stale"
    assert text =~ "offline insight"
    assert text =~ "record mirror-record"
    assert text =~ ctx.context.source.endpoint
    assert hit.memory_id == "mirror-record"
    assert hit.canonical_id == "mirror-record"

    assert hit.citation == %{
             source_id: "backplane-host",
             endpoint: ctx.context.source.endpoint,
             memory_id: "mirror-record"
           }

    assert public.host_source == "edge_mirror"
    assert public.stale
  end

  test "empty recall and outages have different native outcomes, with sanitized errors", ctx do
    expect(ctx, [])
    assert {:ok, %{content: text, structured: %{hits: []}}} = HostMemory.execute(operation(ctx))
    assert text =~ "No matching host memory records"

    ctx = put_in(ctx.context.source.agent_id, "route-error")
    configure(ctx)
    assert {:ok, [_recall, _get]} = HostMemory.descriptors(ctx.context)

    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/route-error/call/recall",
      &Plug.Conn.resp(&1, 500, "secret-backend-token")
    )

    assert {:error,
            %Error{class: :unsupported_capability, details: %{code: "unavailable"}} = error} =
             HostMemory.execute(operation(ctx))

    refute inspect(error) =~ "secret-backend-token"

    ctx = put_in(ctx.context.source.agent_id, "route-denied")
    configure(ctx)
    assert {:ok, [_recall, _get]} = HostMemory.descriptors(ctx.context)

    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/route-denied/call/recall",
      &Plug.Conn.resp(&1, 401, "secret")
    )

    assert {:error, %Error{class: :forbidden, details: %{code: "unauthorized"}}} =
             HostMemory.execute(operation(ctx))
  end

  test "combined explicit text and structured output have one 64KiB budget", ctx do
    expect(ctx, [%{"id" => "one", "content" => String.duplicate("x", 34_000)}])

    assert {:error, %Error{class: :budget_exceeded, details: %{code: "output_limit"}}} =
             HostMemory.execute(operation(ctx))
  end

  for tool <- ["memory::recall", "memory::get"] do
    @native_tool tool
    test "native #{tool} Execution invokes HTTP and revoked grants create no HTTP or intents",
         ctx do
      native_execution(ctx, @native_tool)
    end
  end

  defp native_execution(ctx, tool) do
    {:ok, descriptors} = HostMemory.descriptors(ctx.context)
    descriptors = Enum.filter(descriptors, &(&1.tool_name == tool))
    authority = %{authority() | grants: [tool], tool_revisions: %{tool => 1}}
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, authority: authority)
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
      if(tool == "memory::get", do: get_operation(ctx), else: operation(ctx))
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "invocation"})

    options = [
      registry: bundle.registry,
      authority: authority,
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2000,
      cleanup_timeout: 500
    ]

    if tool == "memory::get", do: expect_get(ctx), else: expect(ctx, [])

    assert {:ok, _, %{effects: [%{structured: public}]}} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               options
             )

    if tool == "memory::get",
      do: assert(public.record.memory_id == @record_id),
      else: assert(public.hits == [])

    {:ok, denied_table} = EphemeralStore.new(1)
    requests_before = Gaoxy.Test.requests(ctx.server)

    denied = Keyword.put(options, :authority, %{authority | grants: []})

    assert {:error, %Error{class: :forbidden}} =
             Execution.run(
               EphemeralStore,
               denied_table,
               record,
               %{command: {:tool_invoked, 11, input}},
               denied
             )

    assert :ets.tab2list(denied_table) == []
    assert Gaoxy.Test.requests(ctx.server) == requests_before
  end

  defp authority,
    do: %{
      caller: "caller",
      run_id: "run-a",
      grants: ["memory::recall", "memory::get"],
      tool_revisions: %{"memory::recall" => 1, "memory::get" => 1}
    }

  defp operation(ctx),
    do: %{
      tool_name: "memory::recall",
      tool_revision: 1,
      arguments: %{"query" => "Concord"},
      run_id: "run-a",
      incarnation: 1,
      catalog_revision: 1,
      backend_context: ctx.context
    }

  defp get_operation(ctx),
    do: %{operation(ctx) | tool_name: "memory::get", arguments: %{"id" => @record_id}}

  defp expect_get(ctx, content \\ "Exact canonical content") do
    result = %{
      "record" => %{
        "id" => @record_id,
        "canonical_id" => @record_id,
        "kind" => "memory",
        "content" => content,
        "memory_type" => "semantic",
        "tags" => ["concord"],
        "lifecycle_state" => "active"
      },
      "mode" => "online",
      "authority" => "canonical",
      "consistency" => "canonical",
      "stale" => false,
      "history_available" => true
    }

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/get", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"id" => @record_id}
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => result}))
    end)
  end

  defp expect(ctx, hits) do
    result = %{
      "mode" => "online",
      "authority" => "canonical",
      "consistency" => "canonical",
      "stale" => false,
      "history_available" => true,
      "pending_operations" => 0,
      "hits" => hits
    }

    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/synapsis/call/recall",
      &Plug.Conn.resp(&1, 200, Jason.encode!(%{"ok" => true, "result" => result}))
    )
  end

  defp configure(ctx, enabled \\ true) do
    config = %{
      "backend" => "workspace",
      "host_agent" => %{
        "enabled" => enabled,
        "endpoint" => ctx.context.source.endpoint,
        "agent_id" => ctx.context.source.agent_id
      }
    }

    assert {:ok, ^config} = Settings.save(config)
  end
end
