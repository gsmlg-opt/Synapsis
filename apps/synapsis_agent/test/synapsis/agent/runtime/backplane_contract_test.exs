defmodule Synapsis.Agent.Runtime.BackplaneContractTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Error, ToolRegistry}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Tool.Registry, as: HostRegistry

  setup do
    run_id = Ecto.UUID.generate()
    name = "backplane-proof-#{run_id}"
    :ok = HostRegistry.register_module(name, Proof.EchoTool, max_retries: 0)
    {:ok, registration} = HostRegistry.lookup(name)
    on_exit(fn -> HostRegistry.unregister(name) end)

    context = %{
      run_id: run_id,
      project_path: File.cwd!(),
      working_dir: File.cwd!(),
      permission_mode: "ask",
      attended?: false,
      tool_max_retries: 0,
      tool_timeout_ms: 500,
      registration: registration,
      skill_catalog: [%{locator: "proof:assigned-skill"}],
      test_pid: self()
    }

    %{run_id: run_id, name: name, context: context, caller: start_supervised!(Task.Supervisor)}
  end

  test "streams a bounded tool turn through the host Gateway with trusted context", ctx do
    owner = self()

    script = fn request ->
      send(owner, {:provider_request, request})

      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [Proof.completed("Finished")]
      else
        [
          %{type: :content_thinking_delta, delta: "Use echo"},
          %{type: :content_text_delta, delta: "Calling echo"},
          %{type: :usage_updated, usage: %{input_tokens: 4, output_tokens: 2}},
          Proof.call(ctx.name, %{"text" => "hello"}),
          Proof.completed("Calling echo")
        ]
      end
    end

    pid = start_run(ctx, script)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Echo hello")
    assert_receive {:provider_request, first}, 2_000
    assert first.run_id == ctx.run_id
    assert first.incarnation == 1
    assert Enum.all?([first.turn_id, first.step_id, first.attempt_id], &is_binary/1)
    assert_receive {:proof_tool_executed, "hello", context}, 2_000
    assert context.project_path == ctx.context.project_path
    assert context.skill_catalog == ctx.context.skill_catalog
    assert context.run_id == ctx.run_id
    assert_receive {:provider_request, second}, 2_000
    assert second.turn_id == first.turn_id
    refute second.attempt_id == first.attempt_id
    await_terminal(ctx, :run_completed)

    status = Conversation.status(pid)
    assert Enum.map(status.messages, & &1.role) == [:user, :assistant, :tool, :assistant]
    assert Enum.at(status.messages, 2).result == %{content: "hello", is_error: false}
    assert status.conversation.usage == [%{input_tokens: 4, output_tokens: 2}]
    assert_receive {:agent_runtime, _, %{type: :content_text_delta, delta: "Calling echo"}}
    refute_receive {:proof_tool_executed, _, _}
    assert {:error, %Error{class: :resource_conflict}} = Proof.prompt(ctx.caller, pid, "Again")
  end

  test "host denial remains authoritative even when the runtime grants the tool", ctx do
    context = Map.put(ctx.context, :capability_overrides, %{ctx.name => :deny})
    pid = start_run(ctx, tool_script(ctx.name), context: context)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Try echo")
    await_terminal(ctx, :run_completed)
    assert tool_result(pid).is_error
    refute_receive {:proof_tool_executed, _, _}
  end

  test "unattended host approval fails closed", ctx do
    :ok = HostRegistry.register_module(ctx.name, Proof.EchoTool, permission_level: :write)
    {:ok, registration} = HostRegistry.lookup(ctx.name)
    context = Map.put(ctx.context, :registration, registration)
    pid = start_run(ctx, tool_script(ctx.name), context: context)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Try write")
    await_terminal(ctx, :run_completed)
    assert tool_result(pid) == %{is_error: true, content: ":approval_unavailable"}
    refute_receive {:proof_tool_executed, _, _}
  end

  test "a replaced host registration is rejected before execution", ctx do
    pid = start_run(ctx, tool_script(ctx.name))
    :ok = HostRegistry.register_module(ctx.name, Proof.EchoTool, version: "replacement")
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Try echo")
    await_terminal(ctx, :run_completed)
    assert tool_result(pid) == %{is_error: true, content: ":tool_registration_changed"}
    refute_receive {:proof_tool_executed, _, _}
  end

  test "runtime authority rejects ungranted tools before the host backend", ctx do
    authority = %{caller: "synapsis-proof", run_id: ctx.run_id, grants: [], tool_revision: 1}
    pid = start_run(ctx, tool_script(ctx.name), authority: authority)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Try echo")
    await_terminal(ctx, :run_completed)
    assert %{is_error: true, error: %Error{class: :forbidden}} = tool_result(pid)
    refute_receive {:proof_tool_executed, _, _}
  end

  test "invalid arguments never reach the host backend", ctx do
    pid = start_run(ctx, tool_script(ctx.name, %{"text" => 123}))
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Try echo")
    await_terminal(ctx, :run_completed)
    assert %{is_error: true, error: %Error{class: :validation}} = tool_result(pid)
    refute_receive {:proof_tool_executed, _, _}
  end

  test "loads the actual assigned skill through the runtime and host Gateway", ctx do
    :ok = HostRegistry.register_module(ctx.name, Synapsis.Tool.Skill)
    {:ok, registration} = HostRegistry.lookup(ctx.name)
    body = "---\nname: review\ndescription: Review code\n---\nFull assigned skill body"

    entry =
      struct!(Synapsis.SkillCatalog.Entry, %{
        authority: :synapsis,
        source_id: "proof",
        skill_id: "review",
        name: "review",
        description: "Review code",
        locator: "proof:assigned-skill",
        enabled: true,
        prompt_visible: true,
        scope: :agent,
        body: body,
        loader: %{type: :inline, canonical?: true}
      })

    context = %{ctx.context | registration: registration, skill_catalog: [entry]}
    schema = Synapsis.Tool.Skill.parameters()
    script = tool_script(ctx.name, %{"locator" => "proof:assigned-skill"})
    pid = start_run(ctx, script, schema: schema, context: context)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Load assigned skill")
    await_terminal(ctx, :run_completed)

    assert %{is_error: false, content: loaded} = tool_result(pid)
    assert loaded =~ body
    assert loaded =~ "<locator>proof:assigned-skill</locator>"

    refute_receive {:proof_tool_executed, _, _}
  end

  for {label, events, error} <- [
        {"missing terminal", [%{type: :content_text_delta, delta: "partial"}],
         "provider ended without terminal event"},
        {"provider failure", [%{type: :response_failed, error: "fixture failure"}],
         "fixture failure"},
        {"malformed tool", [%{type: :tool_call_completed, tool_call: %{id: "bad"}}],
         "malformed tool call"}
      ] do
    test "fails explicitly on #{label}", ctx do
      pid = start_run(ctx, fn _ -> unquote(Macro.escape(events)) end)
      assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Start")
      await_terminal(ctx, :run_failed)
      assert Conversation.status(pid).error == unquote(error)
      refute_receive {:proof_tool_executed, _, _}
    end
  end

  test "duplicate tool call IDs fail before either tool executes", ctx do
    call = Proof.call(ctx.name, %{"text" => "hello"})
    pid = start_run(ctx, fn _ -> [call, call, Proof.completed("Done")] end)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Start")
    await_terminal(ctx, :run_failed)
    assert Conversation.status(pid).error == "duplicate tool call id"
    refute_receive {:proof_tool_executed, _, _}
  end

  test "cancellation stops the runtime-owned fake provider and reaches terminal state", ctx do
    owner = self()

    script = fn _ ->
      send(owner, {:provider_waiting, self()})

      receive do
        :complete -> [Proof.completed("Late completion")]
      after
        4_000 -> [Proof.completed("Provider deadline")]
      end
    end

    pid = start_run(ctx, script, effect_timeout: 4_000)
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Wait")
    assert_receive {:provider_waiting, provider}, 2_000
    monitor = Process.monitor(provider)
    assert :ok = Conversation.cancel(pid)
    assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 2_000
    await_terminal(ctx, :run_cancelled)
    assert Conversation.status(pid).phase == :terminal
    refute_receive {:proof_tool_executed, _, _}
  end

  defp start_run(ctx, script, opts \\ []) do
    context = Keyword.get(opts, :context, ctx.context)
    schema = Keyword.get(opts, :schema, Proof.EchoTool.parameters())

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, Proof.descriptor(ctx.name, context, schema))

    authority = %{
      caller: "synapsis-proof",
      run_id: ctx.run_id,
      grants: [ctx.name],
      tool_revision: 1
    }

    options =
      Proof.options(ctx.run_id, script,
        registry: registry,
        authority: authority
      )
      |> Keyword.merge(Keyword.drop(opts, [:context, :schema]))

    start_supervised!({Conversation, options})
  end

  defp tool_script(name, arguments \\ %{"text" => "hello"}) do
    fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [Proof.completed("Finished")],
        else: [Proof.call(name, arguments), Proof.completed("Calling tool")]
    end
  end

  defp await_terminal(ctx, type) do
    run_id = ctx.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: ^type}}, 2_000
  end

  defp tool_result(pid),
    do: Conversation.status(pid).messages |> Enum.find(&(&1.role == :tool)) |> Map.fetch!(:result)
end
