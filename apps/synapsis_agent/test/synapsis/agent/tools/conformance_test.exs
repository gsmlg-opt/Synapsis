defmodule Synapsis.Agent.Tools.ConformanceTest do
  use ExUnit.Case, async: false

  @root Path.expand("../../../../../..", __DIR__)
  @capture Path.join(@root, "scripts/backplane/capture-contracts.exs")
  @fixture Path.join(@root, "apps/synapsis_agent/test/fixtures/backplane/1.10.61/contracts.json")

  Code.require_file(Path.join(@root, "scripts/backplane/contracts.exs"))

  alias Backplane.AgentRuntime.{
    Budget,
    Codex,
    Conversation,
    EphemeralStore,
    Error,
    Execution,
    ToolCatalog,
    ToolEffects
  }

  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.BackplaneContractCapture, as: Capture

  defmodule Backend do
    def execute(%{backend_context: context} = operation) do
      committed = if context[:table], do: EphemeralStore.load(context.table, operation.run_id)
      send(context.test_pid, {:backend, operation, committed})

      case context.outcome do
        :success ->
          {:ok, %{content: operation.arguments["text"]}}

        :tool_error ->
          {:ok, %{is_error: true, content: "host tool error"}}

        :error ->
          {:error, Error.new(:execution_failure, "backend failed")}

        :unknown ->
          {:error, Error.new(:unknown_outcome, "external outcome unknown")}

        :rejected ->
          ToolEffects.reject(operation, Error.new(:forbidden, "host refused before dispatch"))

        :forged_rejection ->
          ToolEffects.reject(
            %{operation | arguments: %{"text" => "other"}},
            Error.new(:forbidden, "wrong invocation")
          )
      end
    end
  end

  defmodule FailedCommitStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore
    def store(_, _, _), do: {:error, Error.new(:resource_conflict, "fixture commit refused")}

    def acknowledge_commit(_, _, _),
      do: {:error, Error.new(:resource_conflict, "fixture commit refused")}
  end

  setup do
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 5})

    descriptor = %{
      tool_name: "conformance::effect",
      tool_revision: 1,
      description: "Inert host contract probe",
      schema: Proof.EchoTool.parameters(),
      backend: Backend,
      backend_context: %{test_pid: self(), table: table, outcome: :success},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    authority = %{
      caller: "conformance",
      run_id: "conformance-run",
      grants: [descriptor.tool_name],
      tool_revision: 1
    }

    {:ok, bundle} = ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority)

    %{
      table: table,
      budget: budget,
      descriptor: descriptor,
      bundle: bundle,
      caller: start_supervised!(Task.Supervisor)
    }
  end

  test "native capture script is available offline" do
    assert File.regular?(@capture)
  end

  test "native contract snapshot is pinned" do
    assert File.regular?(@fixture)
  end

  test "pinned public APIs include preparation, child interaction and opt-in plugin bindings" do
    apis = Map.new(Capture.snapshot()["provenance"]["public_apis"], &{&1["module"], &1})
    adapter = apis["Elixir.Backplane.AgentRuntime.ConversationAdapter"]
    assert "prepare_tool/2" in adapter["callbacks"]
    assert "prepare_tool/2" in adapter["optional_callbacks"]

    assert "decide/2" in apis["Elixir.Backplane.AgentRuntime.Approval"]["exports"]

    collaboration = apis["Elixir.Backplane.AgentRuntime.Codex.MultiAgent"]
    assert "bind_contract/3" in collaboration["exports"]
    assert "call_bound/2" in collaboration["exports"]
    assert "resolve_interaction/3" in collaboration["exports"]
    assert "cancel_interaction/3" in collaboration["exports"]
    assert "subscribe/2" in collaboration["exports"]
    assert "unsubscribe/2" in collaboration["exports"]

    session = apis["Elixir.Backplane.AgentRuntime.Codex.Session"]

    for export <- ~w(bind/3 adopt_managed_child/3 validate/2 close/2 status/1) do
      assert export in session["exports"]
    end

    plugins = apis["Elixir.Backplane.AgentRuntime.Plugins.Session"]

    for export <- ~w(start_link/1 snapshot/1 catalog/2 load_skill/3 resource/3 call_tool/4 stop/1) do
      assert export in plugins["exports"]
    end
  end

  test "public native profiles and provenance match the deterministic snapshot" do
    snapshot = Capture.snapshot()
    assert File.read!(@fixture) == Capture.encode(snapshot)
    assert Capture.encode(snapshot) == Capture.encode(Capture.snapshot())
    assert snapshot["provenance"]["version"] == "1.10.61"

    for {_family, profile} <- snapshot["profiles"] do
      assert profile["status"] == "admitted"
      names = Enum.map(profile["descriptors"], & &1["tool_name"])
      assert Enum.sort(profile["authority"]["grants"]) == names

      for descriptor <- profile["descriptors"] do
        authority = profile["authority"]

        assert Map.get(
                 authority["tool_revisions"] || %{},
                 descriptor["tool_name"],
                 authority["tool_revision"]
               ) == descriptor["tool_revision"]

        refute Map.has_key?(descriptor, "backend_context")
        assert is_map(descriptor["bindings"])
      end
    end

    refute Capture.encode(snapshot) =~ ~r/#PID|#Function|#Reference|\/home\//
  end

  test "unconfigured native families fail closed without invoking offline bindings" do
    snapshot = Capture.snapshot()

    for family <- ~w(code_mode collaboration_v2 dynamic extensions services) do
      assert snapshot["unconfigured"][family]["status"] == "unavailable"
      assert snapshot["unconfigured"][family]["error"]["class"] == "unsupported_capability"
    end

    assert snapshot["unconfigured"]["interactive"]["descriptors"] == []

    assert Enum.map(snapshot["unconfigured"]["local"]["descriptors"], & &1["tool_name"]) ==
             ["clock::curr_time", "clock::sleep"]
  end

  test "strict host/native admission refuses extra, missing, duplicate and wildcard grants",
       ctx do
    for grants <- [
          [],
          ["*"],
          [ctx.descriptor.tool_name, "extra"],
          [ctx.descriptor.tool_name, ctx.descriptor.tool_name]
        ] do
      assert {:error, %Error{class: :forbidden}} =
               ToolCatalog.admit_batch([ctx.descriptor],
                 mode: :strict,
                 authority: %{ctx.bundle.authority | grants: grants}
               )
    end

    refute_receive {:backend, _, _}, 20
  end

  test "strict admission refuses revision drift and unsupported schema without rewriting it",
       ctx do
    assert {:error, %Error{class: :forbidden}} =
             ToolCatalog.admit_batch([ctx.descriptor],
               mode: :strict,
               authority: %{ctx.bundle.authority | tool_revision: 2}
             )

    unsupported =
      Map.put(ctx.descriptor, :schema, %{
        "type" => "object",
        "$vocabulary" => %{"https://offline.invalid/vocabulary" => true}
      })

    assert {:error, %Error{}} =
             ToolCatalog.admit_batch([unsupported],
               mode: :strict,
               authority: ctx.bundle.authority
             )

    assert unsupported.schema["$vocabulary"] == %{"https://offline.invalid/vocabulary" => true}
    refute_receive {:backend, _, _}, 20
  end

  test "Execution commits exact normalized identity before the host backend runs", ctx do
    assert {:ok, commit, result} = execute(ctx)
    assert commit.revision == 1
    assert result.effects == [%{content: "hello"}]
    assert_receive {:backend, operation, {:ok, persisted}}
    assert persisted.revision == 1
    assert persisted.run.active_tools[operation.invocation_id].arguments == %{"text" => "hello"}

    assert persisted.run.execution_intents["tool:#{operation.invocation_id}"].operation ==
             Map.delete(operation, :backend_context)

    assert operation.caller == ctx.bundle.authority.caller
    refute Map.has_key?(operation.effective_authority, :backend_context)
  end

  test "Execution refuses stale revision, invalid arguments and revoked authority before commit",
       ctx do
    for {invocation, opts, class} <- [
          {%{invocation() | tool_revision: 2}, [], :forbidden},
          {%{invocation() | arguments: %{"text" => 42}}, [], :validation},
          {invocation(), [authority: %{ctx.bundle.authority | grants: []}], :forbidden}
        ] do
      assert {:error, %Error{class: ^class}} = execute(ctx, invocation, opts)

      assert {:error, %Error{class: :not_found}} =
               EphemeralStore.load(ctx.table, "conformance-run")
    end

    refute_receive {:backend, _, _}, 20
  end

  test "failed store acknowledgement prevents every backend effect", ctx do
    assert {:error, %Error{class: :resource_conflict}} =
             execute(ctx, invocation(), store: FailedCommitStore)

    refute_receive {:backend, _, _}, 20
  end

  for {outcome, expected} <- [
        tool_error: {:ok, %{is_error: true, content: "host tool error"}},
        error: {:error, :execution_failure},
        unknown: {:error, :unknown_outcome},
        rejected: {:ok, :forbidden},
        forged_rejection: {:error, :unknown_outcome}
      ] do
    test "Execution preserves #{outcome} semantics", ctx do
      outcome = unquote(outcome)
      descriptor = put_in(ctx.descriptor, [:backend_context, :outcome], outcome)
      {:ok, bundle} = ToolCatalog.admit_batch([descriptor], authority: ctx.bundle.authority)
      result = execute(%{ctx | bundle: bundle})

      case unquote(Macro.escape(expected)) do
        {:ok, class} when is_atom(class) ->
          assert {:ok, _, %{effects: [%{is_error: true, error: %Error{class: ^class}}]}} = result

        {:ok, content} ->
          assert {:ok, _, %{effects: [^content]}} = result

        {:error, class} ->
          assert {:error, %Error{class: ^class}} = result
      end

      assert_receive {:backend, _, {:ok, %{revision: 1}}}
    end
  end

  test "Conversation executes a real native descriptor alongside a directly admitted host descriptor",
       ctx do
    name = ctx.descriptor.tool_name

    {:ok, native} =
      Codex.profile(:pinned_local, %{}, %{ctx.bundle.authority | grants: ["clock::curr_time"]},
        tools: ["clock::curr_time"]
      )

    descriptors = [ctx.descriptor | Map.values(native.registry.tools)]
    authority = %{ctx.bundle.authority | grants: [name, "clock::curr_time"]}

    assert {:ok, combined} =
             ToolCatalog.admit_batch(descriptors, authority: authority, mode: :strict)

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [Proof.completed("done")]
      else
        [
          Proof.call(name, %{"text" => "native + host"}),
          %{
            type: :tool_call_completed,
            tool_call: %{id: "native-call", name: "clock::curr_time", arguments: %{}}
          },
          Proof.completed("calling")
        ]
      end
    end

    pid = start_conversation(ctx, combined, script, work: 4)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "use the combined catalog")

    assert_receive {:backend, %{tool_name: ^name, arguments: %{"text" => "native + host"}}, _},
                   2_000

    assert_receive {:agent_runtime, "conformance-run", %{type: :run_completed}}, 2_000
    results = Conversation.status(pid).messages |> Enum.filter(&(&1.role == :tool))
    assert length(results) == 2
    assert Enum.all?(results, &(&1.result.is_error == false))
  end

  test "Conversation retains uncertain writes instead of treating a generic error as rejection",
       ctx do
    descriptor = put_in(ctx.descriptor, [:backend_context, :outcome], :error)
    {:ok, bundle} = ToolCatalog.admit_batch([descriptor], authority: ctx.bundle.authority)

    script = fn _ ->
      [Proof.call(descriptor.tool_name, %{"text" => "hello"}), Proof.completed("calling")]
    end

    pid = start_conversation(ctx, bundle, script)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "try write")
    assert_receive {:backend, _, _}, 2_000

    assert_receive {:agent_runtime, "conformance-run",
                    %{type: :run_cancelled, state: :unknown_outcome}},
                   2_000

    assert Conversation.status(pid).run.state == :unknown_outcome
    assert {:error, %Error{}} = Proof.prompt(ctx.caller, pid, "must not replay")
    refute_receive {:backend, _, _}, 20
  end

  defp start_conversation(_ctx, bundle, script, opts \\ []) do
    options =
      Proof.options(
        "conformance-run",
        script,
        Keyword.merge(
          [
            registry: bundle.registry,
            authority: bundle.authority,
            tools: bundle.tools,
            schema_admission: :strict
          ],
          opts
        )
      )

    start_supervised!(%{id: make_ref(), start: {Conversation, :start_link, [options]}})
  end

  defp execute(ctx, input \\ invocation(), opts \\ []) do
    {store, opts} = Keyword.pop(opts, :store, EphemeralStore)

    Execution.run(
      store,
      ctx.table,
      running_record(),
      %{command: {:tool_invoked, 11, input}},
      Keyword.merge(
        [
          registry: ctx.bundle.registry,
          authority: ctx.bundle.authority,
          budget: ctx.budget,
          commit_timeout: 500,
          effect_timeout: 500,
          cleanup_timeout: 500
        ],
        opts
      )
    )
  end

  defp running_record do
    %{
      run_id: "conformance-run",
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
  end

  defp invocation do
    %{
      run_id: "conformance-run",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: "conformance::effect",
      tool_revision: 1,
      arguments: %{"text" => "hello"}
    }
  end
end
