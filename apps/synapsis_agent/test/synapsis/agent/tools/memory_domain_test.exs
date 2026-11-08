defmodule Synapsis.Agent.Tools.MemoryDomainTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, ToolCatalog}
  alias Synapsis.Agent.Tools.MemoryDomain
  alias Synapsis.Config.Store
  alias Synapsis.Memory.{FileAdapter, Settings}

  @moduletag :tmp_dir
  @names ~w(synapsis::memory_source_search synapsis::memory_save synapsis::memory_update)

  setup %{tmp_dir: tmp_dir} do
    previous_dir = System.get_env("SYNAPSIS_MEMORY_DIR")
    previous_adapter = Application.fetch_env(:synapsis_core, :memory_adapter)
    previous_config = Store.get(:memory, "default")
    records = Path.join(tmp_dir, "records")
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace)
    System.put_env("SYNAPSIS_MEMORY_DIR", records)
    Application.put_env(:synapsis_core, :memory_adapter, FileAdapter)
    Synapsis.Memory.Cache.clear()

    on_exit(fn ->
      if previous_dir,
        do: System.put_env("SYNAPSIS_MEMORY_DIR", previous_dir),
        else: System.delete_env("SYNAPSIS_MEMORY_DIR")

      case previous_adapter do
        {:ok, adapter} -> Application.put_env(:synapsis_core, :memory_adapter, adapter)
        :error -> Application.delete_env(:synapsis_core, :memory_adapter)
      end

      case previous_config do
        {:ok, entry} -> Store.put(:memory, entry)
        {:error, :not_found} -> Store.delete(:memory, "default")
      end

      Synapsis.Memory.Cache.clear()
    end)

    context = %{
      project_id: "persisted-project",
      session_id: "persisted-session",
      agent_id: "persisted-agent",
      agent_scope: :agent,
      project_path: workspace,
      records_root: records,
      run_id: "session/root/child",
      incarnation: 2,
      catalog_revision: 3
    }

    %{context: context, records: records, workspace: workspace}
  end

  test "strict native descriptors publish only exact canonical identities and safe schemas",
       ctx do
    assert {:ok, descriptors} = MemoryDomain.descriptors(ctx.context)
    assert Enum.map(descriptors, & &1.tool_name) == @names

    authority = %{
      caller: "host",
      run_id: ctx.context.run_id,
      grants: @names,
      tool_revisions: Map.new(@names, &{&1, 1})
    }

    assert {:ok, %{accepted: @names}} = ToolCatalog.admit_batch(descriptors, authority: authority)

    assert {:error, %Error{class: :forbidden}} =
             ToolCatalog.admit_batch(descriptors,
               authority: %{authority | grants: ["*"]}
             )

    for descriptor <- descriptors do
      assert descriptor.backend == MemoryDomain
      assert descriptor.schema["additionalProperties"] == false
      assert descriptor.backend_context.agent_id == "persisted-agent"
      assert descriptor.safety.read_only == (descriptor.tool_name == hd(@names))

      unless descriptor.safety.read_only do
        refute descriptor.safety.retry_safe
        refute descriptor.safety.parallel_safe
      end
    end
  end

  test "real session and agent ownership does not require a fabricated project record", ctx do
    context = Map.delete(ctx.context, :project_id)
    assert {:ok, [_, descriptor, _]} = MemoryDomain.descriptors(context)
    assert descriptor.backend_context.project_id == nil
    ctx = %{ctx | context: descriptor.backend_context}
    op = operation(ctx, "synapsis::memory_save", %{"memories" => [memory("No project record")]})
    assert {:ok, %{resource: resource}} = MemoryDomain.classify(ctx.context, op)
    refute resource =~ ":project:"
    assert resource =~ ":agent:persisted-agent:shared:session:persisted-session"
    assert {:ok, %{structured: %{results: [%{id: id}]}}} = MemoryDomain.execute(op)

    assert {:ok, %{scope_id: "persisted-agent", contributed_by: "persisted-agent"}} =
             Synapsis.Memory.get_semantic(id)
  end

  test "source search defaults to workspace with real citations and no record fallback", ctx do
    File.write!(Path.join(ctx.workspace, "MEMORY.md"), "# Memory\nUse Concord.\n")
    assert {:ok, %{content: content, structured: public}} = search(ctx, %{"query" => "Concord"})
    assert public.ranking == "lexical"

    assert [%{path: "MEMORY.md", from: 2, to: 2}] =
             Enum.map(
               public.results,
               &Map.take(&1, [:path, :from, :to])
             )

    assert content =~ "MEMORY.md:2-2"
    refute File.exists?(ctx.records)
    {:ok, _} = record("shared", "", "Concord")
    File.rm_rf!(ctx.workspace)
    assert {:error, %Error{class: :unsupported_capability}} = search(ctx, %{"query" => "Concord"})
  end

  test "semantic save persists natural and explicit shared scopes with stable authors before events",
       ctx do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:agent:persisted-agent")
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:shared:")
    memories = [memory("Own fact"), Map.put(memory("Shared fact"), "scope", "shared")]

    assert {:ok, %{content: content, structured: %{results: results}}} =
             MemoryDomain.execute(
               operation(ctx, "synapsis::memory_save", %{"memories" => memories})
             )

    assert content =~ "Saved"
    assert [%{status: "saved", id: own}, %{status: "saved", id: shared}] = results

    assert {:ok,
            %{scope: "agent", scope_id: "persisted-agent", contributed_by: "persisted-agent"}} =
             Synapsis.Memory.get_semantic(own)

    assert {:ok, %{scope: "shared", scope_id: "", contributed_by: "persisted-agent"}} =
             Synapsis.Memory.get_semantic(shared)

    assert_receive {:memory_promoted, ^own}
    assert_receive {:memory_promoted, ^shared}

    assert Enum.all?(Path.wildcard(Path.join(ctx.records, "**/*.md")), fn path ->
             not String.contains?(path, [
               "session/root/child",
               "persisted-session",
               "persisted-project"
             ])
           end)

    assert Enum.any?(
             Synapsis.Memory.list_events(scope: "agent", scope_id: "persisted-agent"),
             fn event ->
               event.agent_id == "persisted-agent" and event.type == "memory_promoted" and
                 event.payload.memory_id == own and
                 event.payload.session_id == "persisted-session"
             end
           )
  end

  test "record search preserves agent plus shared visibility, filters and bounded limit", ctx do
    {:ok, own} = record("agent", "persisted-agent", "Concord own")
    {:ok, shared} = record("shared", "", "Concord shared")
    {:ok, foreign} = record("agent", "foreign-agent", "Concord foreign")
    {:ok, project} = record("project", "persisted-project", "Concord project")
    {:ok, _} = record("session", "persisted-session", "Concord session")
    {:ok, archived} = record("agent", "persisted-agent", "Concord archived")
    :ok = Synapsis.Memory.archive_semantic(archived)

    assert {:ok, %{structured: %{results: results}}} =
             search(ctx, %{
               "source" => "records",
               "query" => "Concord",
               "kinds" => ["fact"],
               "tags" => ["storage"]
             })

    assert MapSet.new(Enum.map(results, & &1.id)) == MapSet.new([own.id, shared.id])
    refute Enum.any?(results, &(&1.id in [foreign.id, project.id, archived.id]))

    assert {:ok, %{structured: %{results: [%{id: id}]}}} =
             search(
               ctx,
               %{"source" => "records", "query" => "Concord", "scope" => "shared", "limit" => 1}
             )

    assert id == shared.id
  end

  test "update archive and restore audit confirmed persisted state before broadcast", ctx do
    {:ok, original} = record("agent", "persisted-agent", "Original")
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:agent:persisted-agent")

    for {action, extra} <- [
          {"update", %{"changes" => %{"title" => "Updated", "confidence" => 0.9}}},
          {"archive", %{}},
          {"restore", %{}}
        ] do
      args = Map.merge(%{"action" => action, "memory_id" => original.id}, extra)

      assert {:ok, %{structured: %{id: id, action: ^action, status: "success"}}} =
               MemoryDomain.execute(operation(ctx, "synapsis::memory_update", args))

      assert id == original.id
      assert {:ok, persisted} = Synapsis.Memory.get_semantic(id)
      assert persisted.title == "Updated"
      assert persisted.contributed_by == "persisted-agent"
      assert is_nil(persisted.archived_at) == (action != "archive")
      assert_receive {:memory_updated, ^id}

      assert Enum.any?(
               Synapsis.Memory.list_events(scope: "agent", scope_id: "persisted-agent"),
               fn event ->
                 event.type == "memory_updated" and event.agent_id == "persisted-agent" and
                   event.payload.memory_id == id and event.payload.action == action and
                   event.payload.previous.title in ["Original", "Updated"]
               end
             )
    end
  end

  test "record search never reuses another admitted records root's cached results", ctx do
    {:ok, original} = record("agent", "persisted-agent", "Concord original root")
    {:ok, [descriptor | _]} = MemoryDomain.descriptors(ctx.context)
    original_ctx = %{ctx | context: descriptor.backend_context}
    args = %{"source" => "records", "query" => "Concord", "tags" => ["storage"]}
    assert {:ok, %{structured: %{results: [%{id: id}]}}} = search(original_ctx, args)
    assert id == original.id

    other_root = Path.join(Path.dirname(ctx.records), "other-records")
    System.put_env("SYNAPSIS_MEMORY_DIR", other_root)

    {:ok, [descriptor | _]} =
      MemoryDomain.descriptors(%{ctx.context | records_root: other_root})

    other_ctx = %{ctx | context: descriptor.backend_context, records: other_root}
    assert {:ok, %{structured: %{results: []}}} = search(other_ctx, args)

    {:ok, other} = record("agent", "persisted-agent", "Concord other root")
    assert {:ok, %{structured: %{results: [%{id: other_id}]}}} = search(other_ctx, args)
    assert other_id == other.id

    System.put_env("SYNAPSIS_MEMORY_DIR", ctx.records)
    assert {:ok, %{structured: %{results: [%{id: original_id}]}}} = search(original_ctx, args)
    assert original_id == original.id
  end

  test "save rejects an own record when shared records already fill the visible limit", ctx do
    assert_save_over_budget(ctx, 0, 128, [memory("Own overflow")])
  end

  test "save rejects the 129th own record before writing or reporting unknown outcome", ctx do
    assert_save_over_budget(ctx, 128, 0, [memory("Own overflow")])
  end

  test "save rejects the whole mixed-scope batch before its first write", ctx do
    assert_save_over_budget(ctx, 64, 63, [
      memory("Own overflow"),
      Map.put(memory("Shared overflow"), "scope", "shared")
    ])
  end

  test "shared-only save still accounts for the complete own and shared visible union", ctx do
    ctx = %{ctx | context: %{ctx.context | agent_scope: :shared}}
    assert_save_over_budget(ctx, 128, 0, [memory("Shared overflow")])
  end

  test "save at the combined visible boundary leaves records searchable and mutable", ctx do
    fill_records(64, 63)

    assert {:ok, %{structured: %{results: [%{status: "saved", id: id}]}}} =
             MemoryDomain.execute(
               operation(ctx, "synapsis::memory_save", %{
                 "memories" => [Map.put(memory("Boundary record"), "scope", "shared")]
               })
             )

    assert length(Path.wildcard(Path.join(ctx.records, "**/*.md"))) == 128

    assert {:ok, %{structured: %{results: [%{id: ^id}]}}} =
             search(ctx, %{"source" => "records", "query" => "Boundary"})

    assert {:ok, %{structured: %{status: "success"}}} =
             MemoryDomain.execute(
               operation(ctx, "synapsis::memory_update", %{
                 "action" => "archive",
                 "memory_id" => id
               })
             )
  end

  test "foreign and project/session records cannot be mutated by an agent record capability",
       ctx do
    for {scope, scope_id} <- [
          {"agent", "foreign"},
          {"project", "persisted-project"},
          {"session", "persisted-session"}
        ] do
      {:ok, original} = record(scope, scope_id, "Private")

      assert {:error, %Error{class: :forbidden}} =
               MemoryDomain.execute(
                 operation(ctx, "synapsis::memory_update", %{
                   "action" => "archive",
                   "memory_id" => original.id
                 })
               )

      assert {:ok, %{archived_at: nil}} = Synapsis.Memory.get_semantic(original.id)
    end
  end

  test "full input validation rejects ownership, path and malformed fields before saving", ctx do
    for bad <- [
          %{"scope" => "project"},
          %{"scope_id" => "other"},
          %{"contributed_by" => "other"},
          %{"id" => "../outside"},
          %{"kind" => "unknown"},
          %{"title" => ""},
          %{"summary" => <<255>>},
          %{"tags" => [1]},
          %{"importance" => 1.1}
        ] do
      assert {:error, %Error{class: :validation}} =
               MemoryDomain.execute(
                 operation(ctx, "synapsis::memory_save", %{
                   "memories" => [memory("Valid"), Map.merge(memory("Bad"), bad)]
                 })
               )

      refute File.exists?(ctx.records)
    end

    for source <- ["workspace", "host_agent"], key <- ["scope", "kinds", "tags"] do
      assert {:error, %Error{class: :validation}} =
               search(
                 ctx,
                 %{"source" => source, "query" => "test", key => "shared"}
               )
    end

    for args <- [
          %{"action" => "archive", "memory_id" => "../outside"},
          %{"action" => "unknown", "memory_id" => "safe"},
          %{"action" => "update", "memory_id" => "safe", "changes" => %{"scope" => "shared"}}
        ] do
      assert {:error, %Error{class: :validation}} =
               MemoryDomain.execute(operation(ctx, "synapsis::memory_update", args))
    end
  end

  test "exact bindings reject stale scope and accept only documented native context additions",
       ctx do
    File.write!(Path.join(ctx.workspace, "MEMORY.md"), "Concord\n")
    op = operation(ctx, hd(@names), %{"query" => "Concord"})

    for field <- [:run_id, :incarnation, :catalog_revision, :tool_revision] do
      assert {:error, %Error{class: :forbidden}} =
               MemoryDomain.execute(Map.put(op, field, "stale"))
    end

    enriched =
      Map.merge(ctx.context, %{
        interact: fn _ -> flunk("must not invoke interact") end,
        resource_owner_pid: self(),
        catalog_snapshot: fn -> flunk("must not invoke catalog") end
      })

    assert {:ok, _} = MemoryDomain.execute(%{op | backend_context: enriched})

    assert {:error, %Error{class: :validation}} =
             MemoryDomain.execute(%{
               op
               | backend_context: Map.put(ctx.context, :unknown_callback, fn -> :ok end)
             })

    for bad <- ["../foreign", "/root/child", ""] do
      assert {:error, %Error{class: :validation}} =
               MemoryDomain.descriptors(%{ctx.context | agent_id: bad})
    end
  end

  test "semantic scope links and oversized source files fail without mutation", ctx do
    outside = Path.join(Path.dirname(ctx.records), "outside")
    File.mkdir_p!(outside)
    File.mkdir_p!(ctx.records)
    File.ln_s!(outside, Path.join(ctx.records, "agent"))

    assert {:error, %Error{class: :forbidden}} =
             MemoryDomain.execute(
               operation(ctx, "synapsis::memory_save", %{"memories" => [memory("Escape")]})
             )

    assert File.ls!(outside) == []
    File.rm!(Path.join(ctx.records, "agent"))
    {:ok, entry} = record("agent", "persisted-agent", "Large")
    path = Path.join([ctx.records, "agent", "persisted-agent", "#{entry.id}.md"])
    File.write!(path, String.duplicate("x", 65_537), [:append])

    assert {:error, %Error{class: :budget_exceeded}} =
             search(
               ctx,
               %{"source" => "records", "query" => "Large"}
             )
  end

  test "disabled host and unsupported semantic adapters fail explicitly without remote access",
       ctx do
    server = Gaoxy.Test.open()

    assert {:ok, _} =
             Settings.save(%{
               "backend" => "workspace",
               "host_agent" => %{
                 "enabled" => false,
                 "endpoint" => String.trim_trailing(Gaoxy.Test.url(server), "/"),
                 "agent_id" => "fixture"
               }
             })

    assert {:error, %Error{class: :forbidden}} =
             search(
               ctx,
               %{"source" => "host_agent", "query" => "test"}
             )

    assert %{entries: [], dropped: 0} = Gaoxy.Test.requests(server)
    Application.put_env(:synapsis_core, :memory_adapter, __MODULE__)

    assert {:error, %Error{class: :unsupported_capability}} =
             search(
               ctx,
               %{"source" => "records", "query" => "test"}
             )

    assert {:error, %Error{class: :unsupported_capability}} =
             MemoryDomain.execute(
               operation(ctx, "synapsis::memory_save", %{
                 "memories" => [memory("No unsupported write")]
               })
             )

    refute File.exists?(ctx.records)
  end

  test "replacing an admitted semantic root or scope parent with a link denies every access",
       ctx do
    {:ok, record} = record("agent", "persisted-agent", "Retained")
    {:ok, [descriptor | _]} = MemoryDomain.descriptors(ctx.context)
    ctx = %{ctx | context: descriptor.backend_context}
    record_path = Path.join([ctx.records, "agent", "persisted-agent", "#{record.id}.md"])
    before = File.read!(record_path)

    for {parent, suffix} <- [{ctx.records, "root"}, {Path.join(ctx.records, "agent"), "scope"}] do
      outside = Path.join(Path.dirname(ctx.records), "replaced-#{suffix}")
      File.rename!(parent, outside)
      File.ln_s!(outside, parent)

      assert {:error, %Error{class: :forbidden}} =
               search(ctx, %{"source" => "records", "query" => "Retained"})

      assert {:error, %Error{class: :forbidden}} =
               MemoryDomain.execute(
                 operation(ctx, "synapsis::memory_save", %{"memories" => [memory("Escape")]})
               )

      assert {:error, %Error{class: :forbidden}} =
               MemoryDomain.execute(
                 operation(ctx, "synapsis::memory_update", %{
                   "action" => "archive",
                   "memory_id" => record.id
                 })
               )

      assert File.read!(record_path) == before
      assert length(Path.wildcard(Path.join(outside, "**/*.md"))) == 1

      File.rm!(parent)
      File.rename!(outside, parent)
    end
  end

  test "confirmed updates retain string scalars and every requested changed field", ctx do
    {:ok, original} = record("agent", "persisted-agent", "Original")

    changes = %{
      "title" => "true",
      "summary" => "Updated body.",
      "kind" => "warning",
      "tags" => ["true", "123", "a,b", "[storage]"],
      "importance" => 0.4,
      "confidence" => 0.6
    }

    assert {:ok, %{structured: %{status: "success"}}} =
             MemoryDomain.execute(
               operation(ctx, "synapsis::memory_update", %{
                 "action" => "update",
                 "memory_id" => original.id,
                 "changes" => changes
               })
             )

    assert {:ok, updated} = Synapsis.Memory.get_semantic(original.id)

    for {key, value} <- changes do
      assert Map.fetch!(updated, String.to_existing_atom(key)) == value
    end

    assert updated.contributed_by == "persisted-agent"
  end

  defp search(ctx, args), do: MemoryDomain.execute(operation(ctx, hd(@names), args))

  defp assert_save_over_budget(ctx, own_count, shared_count, memories) do
    fill_records(own_count, shared_count)
    before_paths = Path.wildcard(Path.join(ctx.records, "**/*.md")) |> Enum.sort()
    before_events = Synapsis.Memory.list_events()
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:agent:persisted-agent")
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:shared:")

    assert {:error, %Error{class: :budget_exceeded}} =
             MemoryDomain.execute(
               operation(ctx, "synapsis::memory_save", %{"memories" => memories})
             )

    assert Path.wildcard(Path.join(ctx.records, "**/*.md")) |> Enum.sort() == before_paths
    assert Synapsis.Memory.list_events() == before_events
    refute_receive {:memory_promoted, _}
  end

  defp fill_records(own_count, shared_count) do
    for {scope, scope_id, count} <- [
          {"agent", "persisted-agent", own_count},
          {"shared", "", shared_count}
        ],
        index <- 1..count//1 do
      assert {:ok, _} = record(scope, scope_id, "Existing #{scope} #{index}")
    end
  end

  defp memory(title),
    do: %{"kind" => "fact", "title" => title, "summary" => "Use Concord.", "tags" => ["storage"]}

  defp record(scope, scope_id, title),
    do:
      Synapsis.Memory.store_semantic(%{
        scope: scope,
        scope_id: scope_id,
        kind: "fact",
        title: title,
        summary: "Use Concord.",
        tags: ["storage"],
        contributed_by: "persisted-agent",
        importance: 0.8,
        confidence: 0.8,
        freshness: 1.0
      })

  defp operation(ctx, name, arguments),
    do: %{
      tool_name: name,
      tool_revision: 1,
      arguments: arguments,
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      catalog_revision: ctx.context.catalog_revision,
      backend_context: ctx.context
    }
end
