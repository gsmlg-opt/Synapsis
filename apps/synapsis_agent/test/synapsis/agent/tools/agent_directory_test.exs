defmodule Synapsis.Agent.Tools.AgentDirectoryTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{
    Budget,
    EphemeralStore,
    Error,
    Execution,
    InputSchema,
    ToolCatalog
  }

  alias Backplane.AgentRuntime.ToolEffects
  alias Synapsis.Agent.Tools.{AgentDirectory, ResultProjection}
  alias Synapsis.Config.Store
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @name "synapsis::agents_list"
  @supervisor Synapsis.Config.Store.Supervisor
  @child {Store.Server, :agent}
  @table :synapsis_config_agent
  @private "PRIVATE_NATIVE_AGENT_DIRECTORY"

  setup %{tmp_dir: tmp_dir} do
    assert Code.ensure_loaded?(AgentDirectory),
           "native configured Agent directory is not implemented"

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "config")
    File.mkdir_p!(config_dir)
    File.chmod!(config_dir, 0o700)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)
    File.write!(Store.file_path(:agent), "")
    ensure_server_started()
    assert :ok = Store.reload(:agent)
    :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    :ok = SessionStore.put_meta(session_id, %{id: session_id, agent: "main"})
    requester = put_agent("main", %{"label" => "Main"})

    on_exit(fn ->
      ensure_server_started()
      SessionStore.delete_session(session_id)

      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      assert :ok = Store.reload(:agent)
    end)

    %{
      requester: requester,
      context: %{
        session_id: session_id,
        requester_name: "main",
        run_id: "/root/研究者/child:2",
        incarnation: 1,
        catalog_revision: 1
      }
    }
  end

  test "one strict revision-one read descriptor exposes only bounded page inputs", ctx do
    assert AgentDirectory.names() == [@name]
    assert AgentDirectory.permission_level(@name) == :read
    assert {:ok, [descriptor]} = AgentDirectory.descriptors(ctx.context)
    assert descriptor.tool_name == @name
    assert descriptor.tool_revision === 1
    assert descriptor.backend == AgentDirectory
    assert descriptor.backend_context === ctx.context
    assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
    assert descriptor.schema["additionalProperties"] == false
    assert descriptor.schema["required"] == []
    assert Enum.sort(Map.keys(descriptor.schema["properties"])) == ~w(cursor limit)
    assert descriptor.schema["properties"]["limit"]["minimum"] == 1
    assert descriptor.schema["properties"]["limit"]["maximum"] == 100
    assert descriptor.schema["properties"]["cursor"]["maxLength"] == 4_096
    assert String.downcase(descriptor.description) =~ "configured"

    assert {:ok, _} =
             ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority(ctx))

    for key <-
          ~w(requester requester_name agent_id session_id provider root deadline run_id config) do
      assert {:error, %Error{}} = InputSchema.validate(descriptor.schema, %{key => "forged"})
    end
  end

  test "classification is pure, deterministic and binds session, requester and page independently of run",
       ctx do
    put_agent("alpha")
    assert {:ok, %{structured: first}} = AgentDirectory.execute(operation(ctx, %{"limit" => 1}))
    input = %{"limit" => 1, "cursor" => first.next_cursor}

    [{server, _}] = Registry.lookup(Synapsis.Config.Store.Registry, :agent)
    assert :ok = :sys.suspend(server)

    try do
      assert {:ok, %{action: "agent.directory.list", resource: resource} = classification} =
               AgentDirectory.classify(ctx.context, operation(ctx, input))

      assert is_binary(resource)
      assert resource =~ ctx.context.session_id
      assert resource =~ ctx.context.requester_name
      refute resource =~ ctx.context.run_id

      assert {:ok, ^classification} =
               AgentDirectory.classify(ctx.context, operation(ctx, input))

      other_run = put_in(ctx.context.run_id, "/root/different:3")

      assert {:ok, ^classification} =
               AgentDirectory.classify(other_run.context, operation(other_run, input))

      for changed <- [
            put_in(ctx.context.session_id, Ecto.UUID.generate()),
            put_in(ctx.context.requester_name, "other")
          ] do
        assert {:ok, %{resource: different}} =
                 AgentDirectory.classify(changed.context, operation(changed, input))

        refute different == resource
      end

      for args <- [%{"limit" => 2, "cursor" => first.next_cursor}, %{"limit" => 1}] do
        assert {:ok, %{resource: different}} =
                 AgentDirectory.classify(ctx.context, operation(ctx, args))

        refute different == resource
      end
    after
      :sys.resume(server)
    end
  end

  test "real native Execution returns public configured identities without claiming child availability",
       ctx do
    alpha = put_agent("alpha", %{"label" => "Alpha"})
    put_agent("disabled", %{"enabled" => false})
    [{id, raw}] = :ets.lookup(@table, ctx.requester["id"])

    assert :ets.insert(@table, {
             id,
             Map.merge(raw, %{
               provider: @private,
               model: @private,
               system_prompt: String.duplicate(@private, 10_000),
               config: %{credentials: %{token: @private}},
               tools: [@private]
             })
           })

    assert {:ok, _, %{effects: [result]}} = native(ctx, %{})
    refute Map.get(result, :is_error, false)

    assert result.structured == %{
             requester: %{id: ctx.requester["id"], name: "main"},
             agents: [
               %{id: alpha["id"], name: "alpha", label: "Alpha", configured: true},
               %{id: ctx.requester["id"], name: "main", label: "Main", configured: true}
             ],
             count: 2,
             has_more: false,
             next_cursor: nil
           }

    assert is_binary(result.content) and byte_size(result.content) > 0
    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
    assert byte_size(Jason.encode!(result)) <= 65_536

    for forbidden <- [
          @private,
          ctx.context.run_id,
          "allowAny",
          "spawn_allowed",
          "children",
          "pid"
        ] do
      refute Jason.encode!(result) =~ forbidden
    end

    assert {:ok, _} = ResultProjection.to_part("directory", {:ok, result}, tool_name: @name)
  end

  test "native pages preserve the directory cursor and requester identity", ctx do
    put_agent("alpha")
    assert {:ok, _, %{effects: [first]}} = native(ctx, %{"limit" => 1})
    assert [%{name: "alpha"}] = first.structured.agents
    assert first.structured.has_more

    assert {:ok, _, %{effects: [last]}} =
             native(ctx, %{"limit" => 1, "cursor" => first.structured.next_cursor})

    assert [%{name: "main"}] = last.structured.agents
    assert first.structured.requester == last.structured.requester
    refute last.structured.has_more
    assert last.structured.next_cursor == nil
  end

  test "descriptor context is closed and cannot carry raw Agent configuration", ctx do
    for context <- [
          Map.delete(ctx.context, :requester_name),
          Map.put(ctx.context, :agent, %{name: "main", config: %{token: @private}}),
          Map.put(ctx.context, :agent_id, "main"),
          Map.put(ctx.context, :primary, true),
          Map.put(ctx.context, :store, AnotherStore),
          Map.put(ctx.context, :deadline, 0),
          %{ctx.context | requester_name: "../main"},
          %{ctx.context | requester_name: "main\n"},
          %{ctx.context | requester_name: String.duplicate("a", 257)},
          %{ctx.context | session_id: ctx.context.run_id},
          %{ctx.context | incarnation: 1.0},
          %{ctx.context | catalog_revision: 0}
        ] do
      assert {:error, %Error{class: :validation}} = AgentDirectory.descriptors(context)
    end

    op = operation(ctx, %{})

    enriched =
      Map.merge(ctx.context, %{
        resource_owner_pid: self(),
        interact: fn _ -> flunk("read directory must not interact") end,
        goal: nil,
        goal_binding: nil
      })

    assert {:ok, %{structured: %{requester: %{name: "main"}}}} =
             AgentDirectory.execute(%{op | backend_context: enriched})

    forged = %{op | backend_context: Map.put(enriched, :requester, "other")}
    assert %Error{class: :validation} = invocation_error(AgentDirectory.execute(forged), forged)
    assert :ok = AgentDirectory.cancel(op)
  end

  test "foreign scope and noninteger revisions never dispatch as trusted caller", ctx do
    op = operation(ctx, %{})

    for {key, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 2,
          tool_revision: 1.0,
          backend_context: %{ctx.context | requester_name: "other"}
        ] do
      changed = Map.put(op, key, value)
      assert {:error, :scope_mismatch} = AgentDirectory.classify(ctx.context, changed)
      assert %Error{} = invocation_error(AgentDirectory.execute(changed), changed)
    end
  end

  test "unknown arguments and tool names fail closed before a directory result", ctx do
    for args <- [
          %{"limit" => 0},
          %{"limit" => 101},
          %{"limit" => 1.0},
          %{limit: 1},
          %{"cursor" => ""},
          %{"cursor" => String.duplicate("x", 4_097)},
          %{"requester_name" => "other"},
          %{"session_id" => Ecto.UUID.generate()},
          %{"include_disabled" => true},
          %{"provider" => @private},
          %{"deadline" => 1}
        ] do
      op = operation(ctx, args)
      assert {:error, :invalid_input} = AgentDirectory.classify(ctx.context, op)
      assert %Error{class: :validation} = invocation_error(AgentDirectory.execute(op), op)
    end

    unknown = %{operation(ctx, %{}) | tool_name: "synapsis::subagents"}
    assert {:error, :invalid_input} = AgentDirectory.classify(ctx.context, unknown)
    assert %Error{} = invocation_error(AgentDirectory.execute(unknown), unknown)
  end

  test "missing grants, wrong revisions and unknown args commit no native execution intent",
       ctx do
    {:ok, [descriptor]} = AgentDirectory.descriptors(ctx.context)

    {:ok, bundle} =
      ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority(ctx))

    input = Map.drop(operation(ctx, %{}), [:backend_context])

    for {changed, changed_authority} <- [
          {input, %{bundle.authority | grants: []}},
          {%{input | tool_revision: 2}, bundle.authority},
          {%{input | arguments: %{"requester_name" => "other"}}, bundle.authority}
        ] do
      {:ok, table} = EphemeralStore.new(1)
      {:ok, budget} = Budget.new(%{work: 2})

      assert {:error, %Error{}} =
               Execution.run(
                 EphemeralStore,
                 table,
                 record(ctx),
                 %{command: {:tool_invoked, 11, changed}},
                 registry: bundle.registry,
                 authority: changed_authority,
                 budget: budget,
                 effect_timeout: 2_000,
                 commit_timeout: 500,
                 cleanup_timeout: 500
               )

      assert :ets.tab2list(table) == []
    end
  end

  test "directory errors use fixed public codes without config diagnostics or fallback", ctx do
    missing = put_in(ctx.context.requester_name, "missing")
    missing_op = operation(missing, %{})
    error = invocation_error(AgentDirectory.execute(missing_op), missing_op)
    assert error.details.code == "requester_unavailable"
    refute inspect(error) =~ @private

    invalid = operation(ctx, %{"cursor" => "opaque"})

    assert invocation_error(AgentDirectory.execute(invalid), invalid).details.code ==
             "invalid_cursor"

    File.write!(Store.file_path(:agent), "[[agents]]\nname = \"#{@private}\"\nid = [")
    assert {:error, {:parse_failed, _}} = Store.reload(:agent)
    op = operation(ctx, %{})
    error = invocation_error(AgentDirectory.execute(op), op)
    assert error.details.code == "invalid_config"
    refute inspect(error) =~ @private

    assert :ok = Supervisor.terminate_child(@supervisor, @child)
    error = invocation_error(AgentDirectory.execute(op), op)
    assert error.details.code == "storage_unavailable"
    assert :ets.info(@table) == :undefined
  end

  test "public text and structured data fit the native output budget or fail explicitly", ctx do
    entries =
      for n <- 1..99 do
        id = Ecto.UUID.generate()
        {id, %{id: id, name: "agent_#{n}", enabled: true, label: String.duplicate("L", 800)}}
      end

    assert :ets.insert(@table, entries)
    op = operation(ctx, %{})
    error = invocation_error(AgentDirectory.execute(op), op)
    assert error.details.code == "output_too_large"

    assert {:ok, _, %{effects: [small]}} = native(ctx, %{"limit" => 1})
    assert byte_size(Jason.encode!(small)) <= 65_536
    assert {:ok, _} = ResultProjection.to_part("directory", {:ok, small}, tool_name: @name)
  end

  test "model-visible page and structured sidecar share one native output budget", ctx do
    entries =
      for n <- 1..99 do
        id = Ecto.UUID.generate()
        {id, %{id: id, name: "agent_#{n}", enabled: true, label: String.duplicate("L", 300)}}
      end

    assert :ets.insert(@table, entries)
    assert {:ok, page} = Synapsis.AgentConfigs.directory("main")
    assert byte_size(Jason.encode!(page)) < 65_536
    op = operation(ctx, %{})
    error = invocation_error(AgentDirectory.execute(op), op)
    assert error.details.code == "output_too_large"
  end

  defp invocation_error({:error, %Error{} = error}, _operation), do: error

  defp invocation_error({:rejected, proof}, operation) do
    assert {:ok, %{error: %Error{} = error}} = ToolEffects.validate_rejection(proof, operation)
    error
  end

  defp native(ctx, args) do
    {:ok, descriptors} = AgentDirectory.descriptors(ctx.context)
    {:ok, bundle} = ToolCatalog.admit_batch(descriptors, mode: :strict, authority: authority(ctx))
    {:ok, table} = EphemeralStore.new(1)
    {:ok, budget} = Budget.new(%{work: 2})
    input = Map.drop(operation(ctx, args), [:backend_context])

    Execution.run(EphemeralStore, table, record(ctx), %{command: {:tool_invoked, 11, input}},
      registry: bundle.registry,
      authority: bundle.authority,
      budget: budget,
      effect_timeout: 2_000,
      commit_timeout: 500,
      cleanup_timeout: 500
    )
  end

  defp authority(ctx),
    do: %{
      caller: "agent-directory-test",
      run_id: ctx.context.run_id,
      grants: [@name],
      tool_revisions: %{@name => 1}
    }

  defp record(ctx),
    do: %{
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      expected_revision: 0,
      state: :running,
      admitted: true,
      current_step: %{step_id: "step", attempt_id: "attempt"},
      deadline: nil,
      outcome: nil,
      context: %{},
      children: []
    }

  defp operation(ctx, args),
    do: %{
      tool_name: @name,
      tool_revision: 1,
      arguments: args,
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      catalog_revision: ctx.context.catalog_revision,
      backend_context: ctx.context,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: Ecto.UUID.generate()
    }

  defp put_agent(name, attrs \\ %{}) do
    raw = Map.merge(%{"id" => Ecto.UUID.generate(), "name" => name, "enabled" => true}, attrs)
    assert {:ok, ^raw} = Store.put(:agent, raw)
    raw
  end

  defp ensure_server_started do
    case List.keyfind(Supervisor.which_children(@supervisor), @child, 0) do
      {@child, pid, _, _} when is_pid(pid) ->
        assert Process.alive?(pid)
        assert :ok = :sys.resume(pid)
        assert [{^pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, :agent)

      {@child, :undefined, _, _} ->
        await_registry_release(System.monotonic_time(:millisecond) + 1_000)
        assert {:ok, pid} = Supervisor.restart_child(@supervisor, @child)
        assert [{^pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, :agent)

      other ->
        flunk("Agent config supervisor child is unavailable: #{inspect(other)}")
    end
  end

  defp await_registry_release(deadline) do
    case Registry.lookup(Synapsis.Config.Store.Registry, :agent) do
      [] ->
        :ok

      [{pid, _}] ->
        refute Process.alive?(pid)
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          5 -> await_registry_release(deadline)
        end
    end
  end
end
