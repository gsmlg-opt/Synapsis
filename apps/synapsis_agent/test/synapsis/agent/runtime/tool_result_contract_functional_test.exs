defmodule Synapsis.Agent.Runtime.ToolResultContractFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  # These fixtures qualify the public native package. Production Skills/workshop
  # selector wiring and their host persistence/UI remain separate consumers.

  alias Backplane.AgentRuntime.{Budget, Codex, Conversation, EphemeralStore, Execution}
  alias Backplane.AgentRuntime.Kernel, as: RunKernel
  alias Backplane.AgentRuntime.ToolRegistry
  alias Backplane.AgentRuntime.Codex.{CodeMode, Session}

  @tool "fixture::contract_read"
  @limits %{output_limit: 131_072, json_limit: 98_304}
  @contract Map.put(@limits, :schema_version, 1)

  defmodule Reader do
    def execute(operation) do
      send(operation.backend_context.observer, {:contract_reader_executed, operation})
      {:ok, operation.backend_context.result}
    end
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.observer, {:contract_provider_request, request, self()})

      Stream.resource(
        fn -> :ready end,
        fn state ->
          receive do
            {:contract_provider_events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  test "selected direct intent survives dispatch, completion and canonical reconstruction" do
    {record, invocation, descriptor, options, store} = direct_fixture()
    observer = self()

    selector = fn selected, identity ->
      send(observer, {:direct_contract_selected, selected, identity})
      {:ok, @limits}
    end

    options = Keyword.put(options, :tool_result_contract, selector)

    assert {:ok, started, prepared} =
             Execution.commit(
               EphemeralStore,
               store,
               record,
               %{command: {:tool_invoked, 10, invocation}},
               options
             )

    assert_receive {:direct_contract_selected, ^descriptor, selected_identity}
    assert selected_identity == Map.drop(invocation, [:arguments])
    assert prepared.operation.result_contract == @contract
    assert [%{operation: operation}] = started.outbox
    assert operation == prepared.operation
    refute_received {:contract_reader_executed, _}

    assert {:ok, %{run: admitted}} = EphemeralStore.load(store, record.run_id)
    intent_key = "tool:#{invocation.invocation_id}"
    assert admitted.execution_intents[intent_key].operation == operation
    assert admitted.execution_intents[intent_key].status == :started

    dispatch_options =
      Keyword.put(options, :tool_result_contract, fn selected, identity ->
        send(observer, {:delivery_contract_selected, selected, identity})
        {:ok, @limits}
      end)

    assert {:ok, [result]} = Execution.dispatch(prepared, dispatch_options)
    assert result == ordinary_result()
    assert_receive {:contract_reader_executed, executed}
    assert Map.drop(executed, [:backend_context]) == operation
    assert executed.backend_context == descriptor.backend_context
    assert executed.result_contract == @contract

    completion = Map.put(invocation, :result, result)

    assert {:ok, completed, settled} =
             Execution.commit(
               EphemeralStore,
               store,
               prepared.run,
               %{command: {:tool_completed, 11, completion}},
               dispatch_options
             )

    assert settled.effect == :none
    assert {:ok, %{run: saved}} = EphemeralStore.load(store, record.run_id)
    assert saved.active_tools == %{}
    assert saved.tool_results == %{invocation.invocation_id => result}
    assert saved.execution_intents[intent_key].status == :consumed
    assert saved.execution_intents[intent_key].operation.result_contract == @contract

    reconstructed = reconstruct(record, [started, completed])
    assert reconstructed == saved
    assert reconstructed.execution_intents[intent_key].operation == operation
    refute_received {:direct_contract_selected, _, _}
    refute_received {:delivery_contract_selected, _, _}
    refute_received {:contract_reader_executed, _}
  end

  test "default selection completes an ordinary direct result with the original intent shape" do
    {record, invocation, descriptor, options, store} = direct_fixture()
    observer = self()

    options =
      Keyword.put(options, :tool_result_contract, fn selected, identity ->
        send(observer, {:default_contract_selected, selected, identity})
        :default
      end)

    assert {:ok, started, prepared} =
             Execution.commit(
               EphemeralStore,
               store,
               record,
               %{command: {:tool_invoked, 20, invocation}},
               options
             )

    assert_receive {:default_contract_selected, ^descriptor, identity}
    assert identity == Map.drop(invocation, [:arguments])
    assert Map.get(prepared.operation, :result_contract) == nil
    assert {:ok, [result]} = Execution.dispatch(prepared, options)
    assert result == ordinary_result()
    assert_receive {:contract_reader_executed, executed}
    assert Map.get(executed, :result_contract) == nil

    assert {:ok, completed, _settled} =
             Execution.commit(
               EphemeralStore,
               store,
               prepared.run,
               %{command: {:tool_completed, 21, Map.put(invocation, :result, result)}},
               options
             )

    assert {:ok, %{run: saved}} = EphemeralStore.load(store, record.run_id)
    assert saved.execution_intents["tool:#{invocation.invocation_id}"].status == :consumed
    assert saved.tool_results[invocation.invocation_id] == result
    assert reconstruct(record, [started, completed]) == saved
    refute_received {:default_contract_selected, _, _}
    refute_received {:contract_reader_executed, _}
  end

  test "real Deno receives the selected nested result and normal completion retains its contract" do
    assert is_binary(System.find_executable("deno")), "run this file inside devenv shell"
    assert CodeMode.lifecycle_capability(%{}) == :verified

    run_id = unique_run("nested")
    names = ["exec", @tool]

    authority = %{
      caller: "result-contract-proof",
      run_id: run_id,
      grants: names,
      tool_revision: 1
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority)

    extension = %{
      name: "contract_read",
      namespace: "fixture",
      description: "Return a finite inert document for native result transport qualification.",
      revision: 1,
      backend: Reader,
      backend_context: %{observer: self(), result: ordinary_result()},
      schema: schema(),
      safety: %{read_only: true, retry_safe: true, parallel_safe: false}
    }

    assert {:ok, profile} =
             Codex.profile(
               :mixed,
               %{session_binding: binding, code_mode_contracts: [extension]},
               authority,
               tools: names
             )

    assert {:ok, store} = EphemeralStore.new(binding.run_incarnation)
    observer = self()

    selector = fn descriptor, identity ->
      if descriptor.backend == Reader and descriptor.tool_name == @tool and
           descriptor.tool_revision == 1 do
        send(observer, {:conversation_contract_selected, identity})
        {:ok, @limits}
      else
        send(observer, {:conversation_contract_defaulted, identity})
        :default
      end
    end

    conversation =
      start_supervised!(
        {Conversation,
         run_id: run_id,
         incarnation: binding.run_incarnation,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{observer: self()},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         tool_result_contract: selector,
         schema_admission: :strict,
         run_timeout: 30_000,
         effect_timeout: 10_000,
         commit_timeout: 5_000,
         cleanup_timeout: 5_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Read the ordinary document twice.")
    assert_receive {:contract_provider_request, _initial, provider}, 5_000
    provider_call(provider, "direct-document", @tool, %{"label" => "ordinary"})

    assert_receive {:conversation_contract_selected, direct_identity}, 5_000
    assert_receive {:contract_reader_executed, direct}, 5_000
    assert direct_identity.invocation_id == direct.invocation_id
    assert direct.result_contract == @contract
    assert direct.tool_call_id == "direct-document"
    assert direct_identity == Map.take(direct, Map.keys(direct_identity))
    refute Map.has_key?(direct_identity, :arguments)

    assert_receive {:contract_provider_request, direct_request, provider}, 5_000

    assert List.last(direct_request.messages).result ==
             Map.put(ordinary_result(), :is_error, false)

    provider_call(provider, "nested-document", "exec", """
    const document = await tools.fixture__contract_read({label: "ordinary"});
    return {content: document.content, structured: document.structured};
    """)

    assert_receive {:conversation_contract_defaulted, outer_identity}, 5_000
    assert outer_identity.tool_name == "exec"
    assert_receive {:conversation_contract_selected, nested_identity}, 10_000
    assert_receive {:contract_reader_executed, nested}, 5_000
    assert nested_identity.invocation_id == nested.invocation_id
    assert nested_identity == Map.take(nested, Map.keys(nested_identity))
    refute Map.has_key?(nested_identity, :arguments)
    assert nested.result_contract == direct.result_contract
    assert nested.enclosing_invocation_id == outer_identity.invocation_id
    assert nested.invocation_id != direct.invocation_id
    assert nested.invocation_id != nested.enclosing_invocation_id

    assert_receive {:contract_provider_request, nested_request, provider}, 10_000

    assert %{status: :completed, is_error: false, value: returned} =
             List.last(nested_request.messages).result

    assert returned ==
             ordinary_result()
             |> Jason.encode!()
             |> Jason.decode!()

    send(provider, {:contract_provider_events, [done()]})
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 10_000
    assert {:ok, %{run: saved}} = EphemeralStore.load(store, run_id)
    assert saved.state == :completed
    assert saved.active_tools == %{}

    for operation <- [direct, nested] do
      intent = saved.execution_intents["tool:#{operation.invocation_id}"]
      assert intent.status == :consumed
      assert intent.operation.result_contract == @contract
      assert intent.operation.invocation_id == operation.invocation_id

      assert saved.tool_results[operation.invocation_id] ==
               Map.put(ordinary_result(), :is_error, false)
    end

    outer = saved.execution_intents["tool:#{outer_identity.invocation_id}"]
    assert outer.status == :consumed
    assert Map.get(outer.operation, :result_contract) == nil
    assert map_size(saved.tool_results) == 3
    refute_received {:conversation_contract_selected, _}
    refute_received {:conversation_contract_defaulted, _}
    refute_received {:contract_reader_executed, _}
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  defp direct_fixture do
    run_id = unique_run("direct")

    record = %{
      run_id: run_id,
      incarnation: 1,
      expected_revision: 0,
      state: :running,
      deadline: nil,
      outcome: nil,
      children: [],
      current_step: %{step_id: "document-step", attempt_id: "document-attempt"}
    }

    invocation = %{
      run_id: run_id,
      incarnation: 1,
      step_id: "document-step",
      attempt_id: "document-attempt",
      invocation_id: "document-invocation",
      tool_call_id: "document-call",
      catalog_revision: 1,
      tool_name: @tool,
      tool_revision: 1,
      arguments: %{"label" => "ordinary"}
    }

    descriptor = %{
      tool_name: @tool,
      tool_revision: 1,
      schema: schema(),
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: Reader,
      backend_context: %{observer: self(), result: ordinary_result()}
    }

    assert {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)
    assert {:ok, budget} = Budget.new(%{work: 1})
    assert {:ok, store} = EphemeralStore.new(1)
    on_exit(fn -> if :ets.info(store) != :undefined, do: :ets.delete(store) end)

    options = [
      registry: registry,
      authority: %{
        caller: "result-contract-proof",
        run_id: run_id,
        grants: [@tool],
        tool_revision: 1
      },
      budget: budget
    ]

    {record, invocation, descriptor, options, store}
  end

  defp reconstruct(record, receipts) do
    Enum.reduce(receipts, record, fn receipt, previous ->
      assert [event] = receipt.transition.events

      kind =
        case event.type do
          "run.tool_invoked" -> :tool_invoked
          "run.tool_completed" -> :tool_completed
        end

      assert {:ok, reconstructed, transition, []} =
               RunKernel.execute(previous, {kind, event.occurred_at, event.payload["input"]})

      assert transition == receipt.transition
      reconstructed
    end)
  end

  defp ordinary_result do
    %{
      content: [%{type: "text", text: "Ordinary instructions: read \"青空\".\nKeep this line.\n"}],
      structured: %{name: "ordinary-document", labels: ["one", "two"], complete: true}
    }
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{"label" => %{"type" => "string"}},
      "required" => ["label"],
      "additionalProperties" => false
    }
  end

  defp provider_call(provider, id, name, arguments) do
    send(
      provider,
      {:contract_provider_events,
       [
         %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}},
         done()
       ]}
    )
  end

  defp done,
    do: %{type: :response_completed, message: %{role: :assistant, content: "Document received."}}

  defp unique_run(label),
    do: "synapsis-result-contract-#{label}-#{System.unique_integer([:positive])}"
end
