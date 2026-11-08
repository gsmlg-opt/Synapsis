defmodule Synapsis.Agent.Tools.FilesystemResultContractFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Budget, Execution, ToolRegistry}
  alias Synapsis.Agent.Runtime.Store
  alias Synapsis.Agent.Tools.{Filesystem, FilesystemResultContract}

  @moduletag :tmp_dir
  @limits %{output_limit: 5_767_168, json_limit: 11_010_048}
  @contract %{schema_version: 1, output_limit: 5_767_168, json_limit: 11_010_048}

  test "issued canonical read selects one persisted finite result contract before dispatch", %{
    tmp_dir: root
  } do
    run_id = Ecto.UUID.generate()

    context = %{
      root: root,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1,
      workspace: %{role: :session, agent_id: "image-reader", session_id: Ecto.UUID.generate()},
      path_environment: %{
        cwd: root,
        os_home: System.user_home(),
        platform: platform(),
        workspace_root: root
      },
      prepared_target_resolver: fn _, _, _ -> {:error, :not_prepared} end,
      execution_options: [
        node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
        model_has_vision: true
      ]
    }

    assert {:ok, descriptors} = Filesystem.descriptors(context)
    [descriptor] = Enum.filter(descriptors, &(&1.tool_name == "synapsis::read"))
    assert descriptor.backend == Filesystem
    assert descriptor.tool_revision == 1
    assert descriptor.backend_context === context

    invocation = %{
      run_id: run_id,
      incarnation: 1,
      step_id: "read-step",
      attempt_id: "read-attempt",
      invocation_id: "image-read-invocation",
      tool_call_id: "image-read-call",
      catalog_revision: 1,
      tool_name: "synapsis::read",
      tool_revision: 1,
      arguments: %{"path" => "texture.png"}
    }

    identity = Map.drop(invocation, [:arguments])
    assert FilesystemResultContract.select(descriptor, identity) == {:ok, @limits}
    assert {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    assert {:ok, budget} = Budget.new(%{work: 1})
    assert {:ok, store} = Store.new(1)
    owner = self()

    selector = fn issued, actual_identity ->
      send(owner, {:read_contract_selected, issued, actual_identity})
      FilesystemResultContract.select(issued, actual_identity)
    end

    record = %{
      run_id: run_id,
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      deadline: nil,
      outcome: nil,
      children: [],
      current_step: %{step_id: "read-step", attempt_id: "read-attempt"}
    }

    # Commit is the public native pre-effect boundary. No dispatch is requested.
    assert {:ok, committed, prepared} =
             Execution.commit(
               Store,
               store,
               record,
               %{command: {:tool_invoked, 10, invocation}},
               registry: registry,
               authority: %{
                 caller: "filesystem-image-contract",
                 run_id: run_id,
                 grants: ["synapsis::read"],
                 tool_revision: 1
               },
               budget: budget,
               tool_result_contract: selector
             )

    assert_receive {:read_contract_selected, ^descriptor, ^identity}, 5_000
    assert prepared.effect == :tool
    assert prepared.adapter == Filesystem
    assert prepared.host_context === context
    assert prepared.operation.result_contract == @contract
    assert prepared.operation.arguments == invocation.arguments
    assert [%{status: :started, operation: operation}] = committed.outbox
    assert operation == prepared.operation

    assert {:ok, aggregate} = Store.load(store, run_id)
    intent = aggregate.run.execution_intents["tool:" <> invocation.invocation_id]
    assert intent.status == :started
    assert intent.operation == operation
    assert Map.get(aggregate.run, :tool_results, %{}) == %{}
  end

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:win32, _} -> :win32
      {:unix, _} -> :linux
    end
  end
end
