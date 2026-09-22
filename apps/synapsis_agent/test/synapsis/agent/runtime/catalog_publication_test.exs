defmodule Synapsis.Agent.Runtime.CatalogPublicationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Error, ToolRegistry}
  alias Synapsis.Agent.Runtime.ToolRegistry, as: HostCatalog
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Tool.Registry, as: HostRegistry

  defmodule Discovery do
    def execute(%{backend_context: context}) do
      send(context.owner, {:discovery_ready, self()})

      receive do
        {:stage, update} ->
          send(context.owner, {:staged, context.stage_catalog.(update)})

          receive do
            :finish -> {:ok, %{content: "discovered"}}
          after
            3_000 -> {:error, Error.new(:timeout, "test discovery was not released")}
          end
      after
        3_000 -> {:error, Error.new(:timeout, "test catalog was not supplied")}
      end
    end
  end

  setup do
    owner = self()
    run_id = Ecto.UUID.generate()
    name = "catalog-echo-#{run_id}"
    :ok = HostRegistry.register_module(name, Proof.EchoTool)
    on_exit(fn -> HostRegistry.unregister(name) end)
    {:ok, registration} = HostRegistry.lookup(name)

    tool = %{
      name: name,
      description: Proof.EchoTool.description(),
      parameters: Proof.EchoTool.parameters(),
      registration: registration
    }

    context = %{
      run_id: run_id,
      project_path: File.cwd!(),
      permission_mode: "auto",
      test_pid: owner
    }

    # Descriptor revisions and catalog revisions deliberately differ.
    {:ok, admitted} = HostCatalog.admit([tool], context, revision: 7, caller: "catalog-test")

    discovery = %{
      tool_name: "discover",
      tool_revision: 7,
      backend: Discovery,
      backend_context: %{owner: owner},
      schema: %{"type" => "object"},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    {:ok, initial} = ToolRegistry.register(%ToolRegistry{}, discovery)
    {:ok, revised} = ToolRegistry.register(admitted.registry, discovery)
    definition = %{name: "discover", description: "Test discovery", parameters: discovery.schema}
    authority = %{admitted.authority | grants: ["discover"]}

    update = %{
      publication_id: "catalog-2",
      run_id: run_id,
      incarnation: 1,
      expected_revision: 1,
      catalog: %{
        revision: 2,
        registry: revised,
        authority: %{authority | grants: ["discover", name]},
        tools: [definition | admitted.tools]
      }
    }

    script = fn request ->
      send(owner, {:catalog_request, request})

      calls = Enum.filter(request.messages, &(&1.role == :tool))

      cond do
        request.catalog_revision == 1 ->
          [
            call("discover", "discover", %{}),
            call("too-early", name, %{"text" => "early"}),
            Proof.completed("Discover")
          ]

        length(calls) == 2 ->
          [call("admitted", name, %{"text" => "allowed"}), Proof.completed("Use new tool")]

        true ->
          [Proof.completed("Done")]
      end
    end

    opts =
      Proof.options(run_id, script,
        registry: initial,
        authority: authority,
        tools: [definition],
        work: 8,
        effect_timeout: 4_000,
        run_timeout: 10_000
      )

    pid = start_supervised!({Conversation, opts})
    supervisor = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(supervisor, pid, "Discover a tool")
    assert_receive {:catalog_request, first}, 2_000
    assert first.catalog_revision == 1
    assert first.tools == [definition]
    assert_receive {:discovery_ready, backend}, 2_000
    %{pid: pid, backend: backend, update: update, name: name, supervisor: supervisor}
  end

  test "publishes host-admitted tools after the batch and reconciles an exact retry", ctx do
    stage(ctx)
    assert Conversation.status(ctx.pid).catalog_revision == 1
    send(ctx.backend, :finish)

    assert_receive {:catalog_request, second}, 2_000
    assert second.catalog_revision == 2
    assert second.tools == ctx.update.catalog.tools
    assert_receive {:proof_tool_executed, "allowed", _}, 2_000
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 2_000
    refute_receive {:proof_tool_executed, "early", _}
    refute_receive {:proof_tool_executed, "allowed", _}

    status = Conversation.status(ctx.pid)

    assert %{result: %{is_error: true, error: %Error{class: :not_found}}} =
             Enum.find(status.messages, &(&1[:tool_call_id] == "too-early"))

    assert {:ok, %{status: :published, catalog_revision: 2}} =
             control(ctx, fn -> Conversation.stage_catalog(ctx.pid, ctx.update) end)

    assert {:error, %Error{class: :resource_conflict}} =
             control(ctx, fn ->
               Conversation.stage_catalog(ctx.pid, %{ctx.update | incarnation: 2})
             end)

    refute Map.has_key?(status.run.context, :registry)
  end

  test "invalid bundles and stale identities leave the active catalog intact", ctx do
    for update <- [
          %{ctx.update | run_id: Ecto.UUID.generate()},
          %{ctx.update | incarnation: 2},
          %{ctx.update | expected_revision: 2},
          put_in(ctx.update, [:catalog, :tools], []),
          put_in(ctx.update, [:catalog, :authority, :grants], [])
        ] do
      assert {:error, %Error{}} =
               control(ctx, fn -> Conversation.stage_catalog(ctx.pid, update) end)

      assert %{catalog_revision: 1, pending_catalog_publication: nil} =
               Conversation.status(ctx.pid)
    end

    stage(ctx)
    send(ctx.backend, :finish)
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 2_000
    assert Conversation.status(ctx.pid).catalog_revision == 2
  end

  test "cancellation discards a staged catalog before another provider attempt", ctx do
    stage(ctx)
    ref = Process.monitor(ctx.backend)
    assert :ok = Conversation.cancel(ctx.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 2_000
    assert %{catalog_revision: 1, pending_catalog_publication: nil} = Conversation.status(ctx.pid)
    refute_receive {:catalog_request, _}
    refute_receive {:proof_tool_executed, _, _}
  end

  defp stage(ctx) do
    send(ctx.backend, {:stage, ctx.update})
    assert_receive {:staged, {:ok, %{status: :staged, catalog_revision: 2}}}, 2_000
  end

  defp control(ctx, fun) do
    task = Task.Supervisor.async_nolink(ctx.supervisor, fun)
    assert {:ok, result} = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
    result
  end

  defp call(id, name, arguments),
    do: %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}
end
