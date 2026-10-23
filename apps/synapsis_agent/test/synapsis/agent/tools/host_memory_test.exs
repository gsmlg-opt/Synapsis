defmodule Synapsis.Agent.Tools.HostMemoryTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Budget, EphemeralStore, Error, Execution, ToolCatalog}
  alias Synapsis.Agent.Tools.HostMemory

  setup do
    server = Gaoxy.Test.open()

    context = %{
      source: %{
        id: "local-host",
        endpoint: String.trim_trailing(Gaoxy.Test.url(server), "/"),
        agent_id: "synapsis"
      },
      run_id: "run-a",
      incarnation: 1,
      catalog_revision: 1
    }

    %{server: server, context: context}
  end

  test "only actual upstream recall descriptor is admitted with exact grant and revision", ctx do
    assert {:ok, [descriptor] = descriptors} = HostMemory.descriptors(ctx.context)
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

    assert {:ok, %{accepted: ["memory::recall"]}} =
             ToolCatalog.admit_batch(descriptors, authority: authority())

    for changed <- [
          %{authority() | grants: ["*"]},
          %{authority() | grants: []},
          %{authority() | tool_revisions: %{"memory::recall" => 2}}
        ] do
      assert {:error, %Error{}} = ToolCatalog.admit_batch(descriptors, authority: changed)
    end
  end

  test "classifies host default partition identity including endpoint, never routing agent or project",
       ctx do
    assert {:ok, %{action: "memory.read", resource: resource}} =
             HostMemory.classify(ctx.context, operation(ctx))

    assert resource =~ "local-host"
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
    assert text =~ "local-host"
    assert text =~ "one"
    refute text =~ "project-a"
    assert [%{memory_id: "one", citation: %{source_id: "local-host"}}] = result.hits
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
             source_id: "local-host",
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

  test "native Execution invokes real HTTP and revoked grants create neither HTTP nor intents",
       ctx do
    {:ok, descriptors} = HostMemory.descriptors(ctx.context)
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
      operation(ctx)
      |> Map.drop([:backend_context])
      |> Map.merge(%{step_id: "step", attempt_id: "attempt", invocation_id: "invocation"})

    options = [
      registry: bundle.registry,
      authority: authority(),
      budget: budget,
      commit_timeout: 500,
      effect_timeout: 2000,
      cleanup_timeout: 500
    ]

    expect(ctx, [])

    assert {:ok, _, %{effects: [%{structured: %{hits: []}}]}} =
             Execution.run(
               EphemeralStore,
               table,
               record,
               %{command: {:tool_invoked, 11, input}},
               options
             )

    {:ok, denied_table} = EphemeralStore.new(1)
    requests_before = Gaoxy.Test.requests(ctx.server)

    denied = Keyword.put(options, :authority, %{authority() | grants: []})

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
      grants: ["memory::recall"],
      tool_revisions: %{"memory::recall" => 1}
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
end
