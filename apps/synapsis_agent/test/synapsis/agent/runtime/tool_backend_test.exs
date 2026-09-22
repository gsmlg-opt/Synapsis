defmodule Synapsis.Agent.Runtime.ToolBackendTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Synapsis.Agent.Runtime.ToolRegistry
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Tool.Capability.{Grant, PolicySnapshot}
  alias Synapsis.Tool.Registry

  defmodule Tool do
    use Synapsis.Tool
    def name, do: "runtime-tool-fixture"
    def description, do: "Inert tool lifecycle fixture"
    def parameters, do: Proof.EchoTool.parameters()
    def permission_level, do: :read

    def execute(%{"text" => text}, context) do
      send(context.test_pid, {:executed, self(), context})

      if text == "block" do
        receive do
          :finish -> {:ok, "finished"}
        after
          5_000 -> {:error, :fixture_deadline}
        end
      else
        {:ok, text}
      end
    end
  end

  setup do
    name = "backend-#{Ecto.UUID.generate()}"
    :ok = Registry.register_module(name, Tool)
    on_exit(fn -> Registry.unregister(name) end)
    run_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()

    host = %{
      run_id: run_id,
      session_id: session_id,
      project_path: File.cwd!(),
      test_pid: self(),
      policy_snapshot:
        PolicySnapshot.from_permission_mode("ask",
          run_id: run_id,
          session_id: session_id,
          attended?: true
        )
    }

    %{name: name, run_id: run_id, host: host, caller: start_supervised!(Task.Supervisor)}
  end

  test "read execution carries trusted context and runtime identity", ctx do
    pid = start_run(ctx)
    assert_receive {:executed, _, host}, 2_000
    assert host.run_id == ctx.run_id
    assert host.project_path == ctx.host.project_path
    assert host.tool_task_link
    assert host.tool_max_retries == 0
    assert is_binary(host.invocation_id)
    completed(ctx)
    assert result(pid) == %{content: "hello", is_error: false}
  end

  test "backend independently checks admitted operation scope and arguments", ctx do
    {:ok, registration} = Registry.lookup(ctx.name)

    tool = %{
      name: ctx.name,
      description: Tool.description(),
      parameters: Tool.parameters(),
      registration: registration
    }

    {:ok, admitted} = ToolRegistry.admit([tool], ctx.host, caller: "test", revision: 1)

    operation = %{
      tool_name: ctx.name,
      run_id: ctx.run_id,
      tool_revision: 1,
      arguments: %{"text" => "hello"},
      backend_context: admitted.registry.tools[ctx.name].backend_context
    }

    for {key, value} <- [run_id: "another", tool_name: "another", tool_revision: 2] do
      assert {:error, %Error{class: :forbidden}} =
               Synapsis.Agent.Runtime.ToolBackend.execute(Map.put(operation, key, value))
    end

    assert {:error, %Error{class: :validation}} =
             Synapsis.Agent.Runtime.ToolBackend.execute(%{
               operation
               | arguments: %{"text" => 123}
             })

    refute_receive {:executed, _, _}, 20
  end

  test "attended approval requires a correlated scoped host grant", ctx do
    write(ctx)
    pid = start_run(%{ctx | host: Map.put(ctx.host, :operator_approval, true)})
    {interaction, request} = approval(ctx)
    refute_receive {:executed, _, _}, 20
    assert request.run_id == ctx.run_id
    assert request.session_id == ctx.host.session_id
    assert request.arguments == %{"text" => "hello"}
    assert {:ok, _, _} = DateTime.from_iso8601(request.expires_at)
    assert :ok = Conversation.resolve(pid, interaction, answer(ctx, request))
    assert_receive {:executed, _, _}, 2_000
    completed(ctx)
    assert result(pid) == %{content: "hello", is_error: false}
    assert {:error, %Error{class: :not_found}} = Conversation.resolve(pid, interaction, true)
  end

  for invalid <- [
        :boolean,
        :correlation,
        :forged,
        :expired,
        :arguments,
        :run,
        :session,
        :tool,
        :source,
        :unbound
      ] do
    test "rejects #{invalid} approval before dispatch", ctx do
      write(ctx)
      pid = start_run(ctx)
      {interaction, request} = approval(ctx)
      valid = answer(ctx, request)

      response =
        case unquote(invalid) do
          :boolean -> true
          :correlation -> %{valid | approval_id: "other"}
          :forged -> %{valid | grant: %{valid.grant | mac: <<0>>}}
          :expired -> answer(ctx, request, ttl_ms: -1)
          :arguments -> answer(ctx, request, input: %{"text" => "other"})
          :run -> answer(ctx, request, run_id: "other")
          :session -> answer(ctx, request, session_id: "other")
          :tool -> answer(ctx, request, tool_name: "other")
          :source -> answer(ctx, request, source: :policy_allow)
          :unbound -> answer(ctx, request, input: nil)
        end

      assert :ok = Conversation.resolve(pid, interaction, response)
      completed(ctx)
      assert %{is_error: true, error: %Error{class: :forbidden}} = result(pid)
      refute_receive {:executed, _, _}, 20
    end
  end

  test "unattended approval does not interact or execute", ctx do
    write(ctx)
    snapshot = %{ctx.host.policy_snapshot | attended?: false}
    pid = start_run(%{ctx | host: %{ctx.host | policy_snapshot: snapshot}})
    completed(ctx)
    assert %{is_error: true, error: %Error{class: :forbidden}} = result(pid)
    refute_receive {:agent_runtime, _, %{type: :interaction_requested}}, 20
    refute_receive {:executed, _, _}, 20
  end

  test "explicit host deny cannot be overridden by a supplied approval flag", ctx do
    snapshot = %{ctx.host.policy_snapshot | capability_overrides: %{ctx.name => :deny}}
    host = ctx.host |> Map.put(:policy_snapshot, snapshot) |> Map.put(:operator_approval, true)
    pid = start_run(%{ctx | host: host})
    completed(ctx)
    assert %{is_error: true, error: %Error{class: :forbidden}} = result(pid)
    refute_receive {:agent_runtime, _, %{type: :interaction_requested}}, 20
    refute_receive {:executed, _, _}, 20
  end

  for change <- [:replacement, :disabled] do
    test "rejects registration #{change} during approval", ctx do
      write(ctx)
      pid = start_run(ctx)
      {interaction, request} = approval(ctx)
      opts = if unquote(change) == :disabled, do: [enabled: false], else: [version: "replacement"]
      :ok = Registry.register_module(ctx.name, Tool, opts)
      assert :ok = Conversation.resolve(pid, interaction, answer(ctx, request))
      completed(ctx)
      assert %{is_error: true, error: %Error{class: :resource_conflict}} = result(pid)
      refute_receive {:executed, _, _}, 20
    end
  end

  test "cancelling a dispatched tool stops its module task", ctx do
    pid = start_run(ctx, arguments: %{"text" => "block"}, effect_timeout: 3_000)
    assert_receive {:executed, task, _}, 2_000
    ref = Process.monitor(task)
    assert :ok = Conversation.cancel(pid)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 2_000
    assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 2_000
  end

  test "host tool timeout is unknown outcome with no automatic retry", ctx do
    pid = start_run(ctx, arguments: %{"text" => "block"}, tool_timeout_ms: 50)
    assert_receive {:executed, task, _}, 2_000
    ref = Process.monitor(task)
    completed(ctx)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 2_000
    assert %{is_error: true, error: %Error{class: :unknown_outcome}} = result(pid)
    refute_receive {:executed, _, _}, 100
  end

  test "runtime effect timeout also stops a dispatched module task", ctx do
    pid = start_run(ctx, arguments: %{"text" => "block"}, effect_timeout: 100)
    assert_receive {:executed, task, _}, 2_000
    ref = Process.monitor(task)
    assert_receive {:agent_runtime, _, %{type: :run_cancelled, state: :unknown_outcome}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 2_000
    assert Conversation.status(pid).phase == :terminal
    refute_receive {:executed, _, _}, 20
  end

  test "conversation owner death stops its running module task", ctx do
    pid = start_run(ctx, arguments: %{"text" => "block"}, effect_timeout: 3_000)
    assert_receive {:executed, task, _}, 2_000
    ref = Process.monitor(task)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 2_000
  end

  test "approval expiry prevents execution even before effect deadline", ctx do
    write(ctx)
    pid = start_run(ctx, approval_timeout_ms: 20)
    {interaction, request} = approval(ctx)
    refute_receive {:executed, _, _}, 30
    assert :ok = Conversation.resolve(pid, interaction, answer(ctx, request))
    completed(ctx)
    assert %{is_error: true, error: %Error{class: :forbidden}} = result(pid)
  end

  for termination <- [:cancel, :timeout] do
    test "#{termination} clears pending approval and rejects late resolution", ctx do
      write(ctx)
      pid = start_run(ctx, effect_timeout: 200)
      {interaction, request} = approval(ctx)

      if unquote(termination) == :cancel do
        assert :ok = Conversation.cancel(pid)
        assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 2_000
      else
        assert_receive {:agent_runtime, _,
                        %{
                          type: :run_cancelled,
                          state: :unknown_outcome,
                          outcome: %{"stop_reason" => "deadline_exceeded"}
                        }},
                       2_000
      end

      assert Conversation.status(pid).conversation.pending_interaction == nil

      assert {:error, %Error{class: :not_found}} =
               Conversation.resolve(pid, interaction, answer(ctx, request))

      refute_receive {:executed, _, _}, 20
    end
  end

  defp write(ctx), do: Registry.register_module(ctx.name, Tool, permission_level: :write)

  defp start_run(ctx, opts \\ []) do
    {:ok, registration} = Registry.lookup(ctx.name)

    tool = %{
      name: ctx.name,
      description: Tool.description(),
      parameters: Tool.parameters(),
      registration: registration
    }

    {:ok, admitted} =
      ToolRegistry.admit(
        [tool],
        ctx.host,
        Keyword.merge(
          [caller: "test", revision: 1, tool_timeout_ms: 2_000],
          Keyword.take(opts, [:tool_timeout_ms, :approval_timeout_ms])
        )
      )

    arguments = Keyword.get(opts, :arguments, %{"text" => "hello"})

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [Proof.completed("Done")],
        else: [Proof.call(ctx.name, arguments), Proof.completed("Calling")]
    end

    options =
      Proof.options(ctx.run_id, script,
        registry: admitted.registry,
        authority: admitted.authority
      )
      |> Keyword.merge(Keyword.take(opts, [:effect_timeout]))

    pid = start_supervised!({Conversation, options})
    assert {:ok, _} = Proof.prompt(ctx.caller, pid, "Start")
    pid
  end

  defp approval(ctx) do
    run_id = ctx.run_id

    assert_receive {:agent_runtime, ^run_id,
                    %{type: :interaction_requested, interaction_id: id, request: request}},
                   2_000

    assert request.kind == :tool_permission
    {id, request}
  end

  defp answer(ctx, request, overrides \\ []) do
    attrs = [
      tool_name: ctx.name,
      permission_level: :write,
      source: :operator_approval,
      session_id: ctx.host.session_id,
      run_id: ctx.run_id,
      input: request.arguments
    ]

    %{approval_id: request.approval_id, grant: Grant.mint(Keyword.merge(attrs, overrides))}
  end

  defp completed(ctx) do
    run_id = ctx.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 2_000
  end

  defp result(pid),
    do: Conversation.status(pid).messages |> Enum.find(&(&1.role == :tool)) |> Map.fetch!(:result)
end
