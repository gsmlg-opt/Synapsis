defmodule Synapsis.Agent.Tools.AutomationsTest do
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
  alias Synapsis.Agent.Tools.{Automations, ResultProjection}
  alias Synapsis.Config.Store
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @name "synapsis::automations"
  @supervisor Synapsis.Config.Store.Supervisor
  @child {Store.Server, :agent}
  @private "PRIVATE_NATIVE_AUTOMATION_DIRECTORY"

  setup %{tmp_dir: tmp_dir} do
    assert Code.ensure_loaded?(Automations),
           "native automation configuration reader is not implemented"

    original_sources =
      for type <- [:agent, :routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        {type, :sys.get_state(pid).load_error, :ets.tab2list(:"synapsis_config_#{type}")}
      end

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "config")
    File.mkdir_p!(config_dir)
    File.chmod!(config_dir, 0o700)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)

    for type <- [:agent, :routine, :heartbeat] do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

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

      for {type, load_error, entries} <- original_sources do
        table = :"synapsis_config_#{type}"
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        :sys.replace_state(pid, &Map.put(&1, :load_error, load_error))
      end
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

  test "strict revision-two descriptor exposes read-only status list get and runs", ctx do
    assert Automations.names() == [@name]
    assert Automations.permission_level(@name) == :read
    assert {:ok, [descriptor]} = Automations.descriptors(ctx.context)
    assert descriptor.tool_revision === 2
    assert descriptor.backend == Automations
    assert descriptor.backend_context === ctx.context
    assert descriptor.safety == %{read_only: true, retry_safe: true, parallel_safe: true}
    assert descriptor.schema["additionalProperties"] == false
    assert descriptor.schema["required"] == ["action"]
    assert descriptor.schema["properties"]["action"]["enum"] == ["status", "list", "get", "runs"]

    assert Enum.sort(Map.keys(descriptor.schema["properties"])) ==
             ~w(action cursor id limit run_id source)

    assert {:ok, _} =
             ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority(ctx))

    assert {:error, %Error{}} = InputSchema.validate(descriptor.schema, %{"action" => "run"})

    assert {:error, %Error{}} =
             InputSchema.validate(descriptor.schema, %{
               "action" => "list",
               "requester_name" => "other"
             })
  end

  test "pure action classification binds session requester exact page or source ID, separately from run",
       ctx do
    [{server, _}] = Registry.lookup(Synapsis.Config.Store.Registry, :agent)
    :ok = :sys.suspend(server)

    try do
      inputs = [
        %{"action" => "status"},
        %{"action" => "list"},
        %{"action" => "list", "limit" => 1},
        %{"action" => "list", "cursor" => "opaque"},
        %{"action" => "get", "source" => "routine", "id" => Ecto.UUID.generate()}
      ]

      resources =
        for input <- inputs do
          assert {:ok, %{action: action, resource: resource} = classified} =
                   Automations.classify(ctx.context, operation(ctx, input))

          assert action == "automation." <> input["action"]
          assert resource =~ ctx.context.session_id
          assert resource =~ ctx.context.requester_name
          refute resource =~ ctx.context.run_id
          changed_run = put_in(ctx.context.run_id, "/root/another:7")

          assert {:ok, ^classified} =
                   Automations.classify(changed_run.context, operation(changed_run, input))

          changed_requester = put_in(ctx.context.requester_name, "other")

          assert {:ok, %{resource: different}} =
                   Automations.classify(
                     changed_requester.context,
                     operation(changed_requester, input)
                   )

          refute resource == different
          resource
        end

      assert length(Enum.uniq(resources)) == 5
    after
      :sys.resume(server)
    end
  end

  @tag :automation_status
  test "native status returns only the scheduler process and last reload observation", ctx do
    scheduler = status_scheduler()
    assert {:ok, _, %{effects: [result]}} = native(ctx, %{"action" => "status"})

    assert %{scheduler: %{engine: "node_local", running: true, reload_status: status}} =
             result.structured

    assert status in ["pending", "ok", "failed"]
    assert Map.keys(result.structured) == [:scheduler]
    assert Enum.sort(Map.keys(result.structured.scheduler)) == ~w(engine reload_status running)a
    assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
    refute Jason.encode!(result) =~ @private
    assert Process.alive?(scheduler)
  end

  test "real native execution returns public list pages then source-qualified get", ctx do
    first = put_routine(:routine, "Alpha", %{enabled: false})
    heartbeat = put_routine(:heartbeat, "Beta")
    hidden = put_routine(:routine, "Other", %{agent_name: "other"})
    assert {:ok, _, %{effects: [page]}} = native(ctx, %{"action" => "list", "limit" => 1})
    assert [%{id: id, enabled: false}] = page.structured.routines
    assert id == first.id
    assert page.structured.has_more

    assert {:ok, _, %{effects: [last]}} =
             native(ctx, %{"action" => "list", "cursor" => page.structured.next_cursor})

    assert [%{id: heartbeat_id, source: "heartbeat"}] = last.structured.routines
    assert heartbeat_id == heartbeat.id

    assert {:ok, _, %{effects: [get]}} =
             native(ctx, %{"action" => "get", "source" => "heartbeat", "id" => heartbeat.id})

    assert get.structured.routine == hd(last.structured.routines)

    for result <- [page, last, get] do
      assert Jason.decode!(result.content) == Jason.decode!(Jason.encode!(result.structured))
      assert byte_size(Jason.encode!(result)) <= 65_536
      refute Jason.encode!(result) =~ @private
      assert {:ok, _} = ResultProjection.to_part("automation", {:ok, result}, tool_name: @name)
    end

    op = operation(ctx, %{"action" => "get", "source" => "routine", "id" => hidden.id})

    assert %Error{class: :not_found, details: %{code: "not_found"}} =
             invocation_error(Automations.execute(op), op)
  end

  test "input branches mutations and caller overrides fail closed", ctx do
    id = Ecto.UUID.generate()

    invalid = [
      %{},
      %{action: "list"},
      %{"action" => "list", "source" => "routine"},
      %{"action" => "get", "source" => "routine", "id" => id, "cursor" => "opaque"},
      %{"action" => "get", "source" => "routine", "id" => String.upcase(id)},
      %{"action" => "list", "limit" => 101},
      %{"action" => "status", "limit" => 1},
      %{"action" => "status", "source" => "routine", "id" => id}
    ]

    invalid =
      invalid ++
        for action <- ~w(runs add update remove run wake), do: %{"action" => action}

    invalid =
      invalid ++
        for key <- ~w(requester_name agent_name session_id root project prompt metadata),
            do: %{"action" => "list", key => "forged"}

    for args <- invalid do
      op = operation(ctx, args)
      assert {:error, :invalid_input} = Automations.classify(ctx.context, op)
      assert %Error{class: :validation} = invocation_error(Automations.execute(op), op)
    end
  end

  test "exact native scope strict context and known execution enrichment are enforced", ctx do
    op = operation(ctx, %{"action" => "list"})

    for context <- [
          Map.put(ctx.context, :agent, %{token: @private}),
          Map.delete(ctx.context, :requester_name),
          %{ctx.context | session_id: ctx.context.run_id},
          %{ctx.context | incarnation: 1.0},
          %{ctx.context | catalog_revision: 0}
        ] do
      assert {:error, %Error{class: :validation}} = Automations.descriptors(context)
    end

    for {key, value} <- [
          run_id: "other",
          incarnation: 1.0,
          catalog_revision: 2,
          tool_revision: 2.0,
          backend_context: %{ctx.context | requester_name: "other"}
        ] do
      changed = Map.put(op, key, value)
      assert {:error, :scope_mismatch} = Automations.classify(ctx.context, changed)
      assert %Error{} = invocation_error(Automations.execute(changed), changed)
    end

    enriched =
      Map.merge(ctx.context, %{
        resource_owner_pid: self(),
        interact: fn _ -> flunk("read must not interact") end,
        goal: nil,
        goal_binding: nil
      })

    assert {:ok, _} = Automations.execute(%{op | backend_context: enriched})
    forged = %{op | backend_context: Map.put(enriched, :requester, "other")}
    assert %Error{class: :validation} = invocation_error(Automations.execute(forged), forged)
    assert :ok = Automations.cancel(op)
  end

  test "missing grants wrong revisions and forged requester commit zero native intents", ctx do
    {:ok, [descriptor]} = Automations.descriptors(ctx.context)

    {:ok, bundle} =
      ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority(ctx))

    input = Map.drop(operation(ctx, %{"action" => "list"}), [:backend_context])

    for {changed, auth} <- [
          {input, %{bundle.authority | grants: []}},
          {%{input | tool_revision: 3}, bundle.authority},
          {%{input | arguments: %{"action" => "list", "requester_name" => "other"}},
           bundle.authority}
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
                 authority: auth,
                 budget: budget,
                 effect_timeout: 2000,
                 commit_timeout: 500,
                 cleanup_timeout: 500
               )

      assert :ets.tab2list(table) == []
    end
  end

  test "native combined text and structured result budget fails explicitly without truncation",
       ctx do
    for n <- 1..60,
        do: put_routine(:routine, "Routine #{n}", %{schedule: String.duplicate("s", 500)})

    assert {:ok, page} = Synapsis.RoutineConfigs.directory("main", limit: 100)
    assert byte_size(Jason.encode!(page)) < 65_536
    op = operation(ctx, %{"action" => "list", "limit" => 100})

    assert %Error{class: :budget_exceeded, details: %{code: "output_too_large"}} =
             invocation_error(Automations.execute(op), op)

    assert {:ok, _} = Automations.execute(operation(ctx, %{"action" => "list", "limit" => 1}))
  end

  test "data health failures have fixed sanitized public error codes", ctx do
    File.write!(Store.file_path(:routine), "[[broken]]\nsecret = [#{@private}")
    assert {:error, {:parse_failed, _}} = Store.reload(:routine)
    op = operation(ctx, %{"action" => "list"})
    error = invocation_error(Automations.execute(op), op)
    assert error.details.code == "invalid_config"
    refute inspect(error) =~ @private
  end

  defp put_routine(type, name, attrs \\ %{}) do
    raw =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: name,
          kind: "schedule",
          enabled: true,
          schedule: "*/5 * * * *",
          prompt: @private
        },
        attrs
      )

    assert :ets.insert(:"synapsis_config_#{type}", {raw.id, raw})
    raw
  end

  defp status_scheduler do
    name = Synapsis.Agent.Heartbeat.LocalScheduler

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        start_supervised!(
          {name,
           config_loader: fn -> [] end,
           config_writer: fn _type, _attrs -> flunk("status must not persist configuration") end}
        )
    end
  end

  defp invocation_error({:error, %Error{} = error}, _operation), do: error

  defp invocation_error({:rejected, proof}, operation) do
    assert {:ok, %{error: %Error{} = error}} = ToolEffects.validate_rejection(proof, operation)
    error
  end

  defp native(ctx, args) do
    {:ok, descriptors} = Automations.descriptors(ctx.context)
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
      tool_revisions: %{@name => 2}
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
      tool_revision: 2,
      arguments: args,
      run_id: ctx.context.run_id,
      incarnation: ctx.context.incarnation,
      catalog_revision: ctx.context.catalog_revision,
      backend_context: ctx.context,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: Ecto.UUID.generate()
    }

  defp put_agent(name, attrs) do
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
