defmodule Synapsis.Session.ChildSessionRuntimeTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{Backend, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.Worker

  @moduletag :tmp_dir
  @tools ~w(exec_command write_stdin spawn_agent followup_task interrupt_agent list_agents wait_agent)
  @start "start retained child"
  @follow "continue retained child"
  @child "start child command"
  @child_follow "continue child command"

  setup %{tmp_dir: tmp_dir} = ctx do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: @tools})
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    install(harness, Map.get(ctx, :scenario, :normal))
    %{harness: harness, id: harness.session.id}
  end

  test "followup reuses the child Session and native command with fresh bound descriptors", ctx do
    first = start_child(ctx)
    binding = child_binding(first)
    assert Session.status(binding.session).phase == :active
    refute binding.resource_registry == :sys.get_state(first.adapter).binding.resource_registry
    assert_bound_catalog(first, binding)
    send(first.handler, :release_child)
    assert_receive {:child_command, command}, 5_000
    assert command =~ "Session ID:"
    assert_receive {:child_list, listing}, 5_000
    refute listing =~ "forbidden"
    assert listing =~ "/root/retained"
    assert_completed()
    assert Session.status(binding.session).phase == :idle
    command_id = Agent.get(ctx.harness.counter, & &1.command_session_id)

    assert {:ok, original_command} =
             ResourceRegistry.fetch_session(
               binding.resource_registry,
               command_id,
               binding.owner_id,
               binding.incarnation
             )

    assert :ok = Worker.send_message(ctx.id, @follow)
    assert_receive {:root_request, handler}, 5_000
    send(handler, :release_root)
    assert_receive {:child_request, @child_follow, handler}, 5_000
    second = child_runtime(ctx.id, handler)
    next = child_binding(second)
    assert second.agent.id == first.agent.id
    assert next.session == binding.session
    assert next.owner_id == binding.owner_id
    assert next.incarnation == binding.incarnation
    assert next.resource_registry == binding.resource_registry
    refute next.token == binding.token
    refute next.run_id == binding.run_id
    assert next.run_incarnation > binding.run_incarnation
    assert_bound_catalog(second, next)

    assert {:ok, ^original_command} =
             ResourceRegistry.fetch_session(
               next.resource_registry,
               command_id,
               next.owner_id,
               next.incarnation
             )

    before = :sys.get_state(:sys.get_state(second.adapter).local_runtime.server)

    assert {:error, %Error{class: :forbidden}} =
             Session.validate(binding, %{
               run_id: binding.run_id,
               incarnation: binding.run_incarnation
             })

    for name <- ["exec_command", "list_agents"] do
      descriptor = first.catalog.registry.tools[name]

      assert {:error, %Error{class: :forbidden}} =
               Backend.execute(%{
                 tool_name: name,
                 backend_context: descriptor.backend_context,
                 run_id: binding.run_id,
                 incarnation: binding.run_incarnation,
                 arguments: %{"cmd" => "touch stale-child-effect", "login" => false}
               })
    end

    assert :sys.get_state(:sys.get_state(second.adapter).local_runtime.server) == before
    refute File.exists?(Path.join(ctx.harness.tmp_dir, "stale-child-effect"))
    send(handler, :release_child)
    assert_receive {:child_stdin, output}, 5_000
    assert output =~ "retained-child=continued"
    assert File.read!(Path.join(ctx.harness.tmp_dir, "child-command-result")) == "continued"
    assert_completed()
  end

  test "root cancellation terminates retained child Session and registry processes", ctx do
    child = start_child(ctx)
    binding = child_binding(child)
    send(child.handler, :release_child)
    assert_receive {:child_command, _}, 5_000
    assert_receive {:child_list, _}, 5_000
    assert_completed()
    pid = command_pid(ctx)
    assert File.exists?("/proc/" <> pid)
    assert :ok = Worker.cancel(ctx.id)
    eventually(fn -> not Process.alive?(binding.session) end)
    eventually(fn -> not Process.alive?(binding.resource_registry) end)
    eventually(fn -> not File.exists?("/proc/" <> pid) end)
    refute File.exists?(Path.join(ctx.harness.tmp_dir, "child-command-result"))
  end

  test "adapter termination stops retained child Session and registry processes", ctx do
    child = start_child(ctx)
    binding = child_binding(child)
    send(child.handler, :release_child)
    assert_receive {:child_command, _}, 5_000
    assert_receive {:child_list, _}, 5_000
    assert_completed()
    pid = command_pid(ctx)
    monitor = Process.monitor(child.adapter)
    Process.exit(child.worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 10_000
    eventually(fn -> not Process.alive?(binding.session) end)
    eventually(fn -> not Process.alive?(binding.resource_registry) end)
    eventually(fn -> not File.exists?("/proc/" <> pid) end)
  end

  @tag scenario: :interrupt
  @tag upstream_blocker: "gsmlg-opt/backplane#99"
  test "native interrupt closes an active child command before root closure stops its owner",
       ctx do
    child = start_child(ctx)
    binding = child_binding(child)
    send(child.handler, :release_child)
    assert_receive {:child_command, _}, 5_000
    assert_receive {:child_command_blocked, _handler}, 5_000
    assert_receive {:root_interrupt_request, handler}, 5_000
    pid = command_pid(ctx)
    command_id = Agent.get(ctx.harness.counter, & &1.command_session_id)
    assert File.exists?("/proc/" <> pid)
    assert Session.status(binding.session).phase == :active
    send(handler, :release_interrupt)
    assert_completed()

    assert [%{status: :interrupted, cleanup: :confirmed}] =
             Worker.snapshot(ctx.id).subagents.agents

    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
             Session.status(binding.session)

    assert {:error, %Error{}} =
             ResourceRegistry.fetch_session(
               binding.resource_registry,
               command_id,
               binding.owner_id,
               binding.incarnation
             )

    eventually(fn -> not File.exists?("/proc/" <> pid) end)
    refute File.exists?(Path.join(ctx.harness.tmp_dir, "child-command-result"))
    assert :ok = Worker.cancel(ctx.id)
    eventually(fn -> not Process.alive?(binding.session) end)
    eventually(fn -> not Process.alive?(binding.resource_registry) end)
  end

  test "a Session reserved before native preparation rejection is cleaned on root close", ctx do
    assert :ok = Worker.send_message(ctx.id, @start)
    assert_receive {:root_request, handler}, 5_000
    runtime = runtime(ctx.id)
    manager_ref = Process.monitor(runtime.manager)
    owner = self()

    :sys.replace_state(runtime.manager, fn manager ->
      original = manager.child_options

      %{
        manager
        | child_options: fn request, run_id, parent ->
            with {:ok, options} <- original.(request, run_id, parent) do
              send(owner, {:unadopted_binding, Keyword.get(options, :session_binding)})
              {:ok, Keyword.put(options, :host_metadata, %{pid: self()})}
            end
          end
      }
    end)

    send(handler, :release_root)
    assert_receive {:unadopted_binding, binding}, 5_000
    assert %{session: session, resource_registry: registry} = binding

    assert_receive {:run_event,
                    %{
                      type: "session.failed",
                      payload: %{"message" => "host metadata must contain safe JSON values"}
                    }},
                   10_000

    assert_receive {:DOWN, ^manager_ref, :process, _, _}, 10_000
    assert {:ok, receipts} = Synapsis.Runtime.Store.list_facts(ctx.id, :admission_receipt)

    assert Enum.any?(receipts, fn receipt ->
             receipt.run_id == binding.run_id and receipt.incarnation == binding.run_incarnation and
               receipt.status == :rejected and receipt.process_started == false
           end)

    assert :ok = Worker.cancel(ctx.id)
    eventually(fn -> not Process.alive?(session) end)
    eventually(fn -> not Process.alive?(registry) end)
    refute_received {:child_request, _, _}
  end

  defp start_child(ctx) do
    assert :ok = Worker.send_message(ctx.id, @start)
    assert_receive {:root_request, handler}, 5_000
    send(handler, :release_root)
    assert_receive {:child_request, @child, handler}, 5_000
    child_runtime(ctx.id, handler)
  end

  defp child_runtime(id, handler) do
    runtime = runtime(id)
    agent = :sys.get_state(runtime.manager).agents["/root/retained"]
    assert is_pid(agent.pid)

    Map.merge(runtime, %{
      agent: agent,
      handler: handler,
      catalog: :sys.get_state(agent.pid).catalog
    })
  end

  defp child_binding(child) do
    assert %{session_binding: binding} =
             child.catalog.registry.tools["exec_command"].backend_context

    binding
  end

  defp assert_bound_catalog(child, binding) do
    for name <- @tools do
      assert child.catalog.registry.tools[name].backend_context.session_binding == binding
    end

    assert child.catalog.registry.tools["exec_command"].backend_context.context.session_registry ==
             binding.resource_registry

    assert child.catalog.registry.tools["exec_command"].backend_context.context.session_binding ==
             binding

    assert :sys.get_state(child.adapter).binding.session != binding.session
  end

  defp install(harness, scenario) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      messages = request["messages"]
      Agent.update(harness.counter, &%{&1 | provider_requests: &1.provider_requests ++ [request]})

      {prompt, index} =
        messages
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find(fn {message, _} ->
          message["role"] == "user" and
            user_text(message) in [@start, @follow, @child, @child_follow]
        end)

      latest = user_text(prompt)
      action_id = if latest == @follow, do: "root-followup", else: "root-spawn"
      wait_id = if latest == @follow, do: "root-wait-followup", else: "root-wait-spawn"
      # Native child-result delivery adds user messages within the operator's turn.
      turn = Enum.drop(messages, index + 1)

      results =
        Map.new(for %{"role" => "tool", "tool_call_id" => id} = result <- turn, do: {id, result})

      cond do
        latest in [@child, @child_follow] ->
          child_response(conn, latest, results, owner, harness, scenario)

        Map.has_key?(results, "root-interrupt") ->
          answer(conn)

        Map.has_key?(results, wait_id) ->
          answer(conn)

        Map.has_key?(results, action_id) ->
          if scenario == :interrupt do
            send(owner, {:root_interrupt_request, self()})

            case AbortableHTTP.await(conn, :release_interrupt, 10_000, owner) do
              {:released, conn} ->
                call(conn, "interrupt_agent", "root-interrupt", %{"target" => "/root/retained"})

              {_, conn} ->
                conn
            end
          else
            call(conn, "wait_agent", wait_id, %{"timeout_ms" => 10_000})
          end

        true ->
          send(owner, {:root_request, self()})

          case AbortableHTTP.await(conn, :release_root, 10_000, owner) do
            {:released, conn} ->
              if latest == @follow do
                call(conn, "followup_task", action_id, %{
                  "target" => "/root/retained",
                  "message" => @child_follow
                })
              else
                call(conn, "spawn_agent", action_id, %{
                  "task_name" => "retained",
                  "message" => @child,
                  "fork_turns" => "none"
                })
              end

            {_, conn} ->
              conn
          end
      end
    end)
  end

  defp child_response(conn, @child, results, owner, harness, scenario) do
    cond do
      Map.has_key?(results, "child-list") ->
        send(owner, {:child_list, results["child-list"]["content"]})
        answer(conn)

      Map.has_key?(results, "child-exec") ->
        content = results["child-exec"]["content"]
        send(owner, {:child_command, content})

        case Regex.run(~r/Session ID: (\d+)/, content) do
          [_, id] ->
            Agent.update(
              harness.counter,
              &Map.put(&1, :command_session_id, String.to_integer(id))
            )

          _ ->
            :ok
        end

        if scenario == :interrupt do
          send(owner, {:child_command_blocked, self()})

          case AbortableHTTP.await(conn, :release_child_completion, 10_000, owner) do
            {:released, conn} -> answer(conn)
            {_, conn} -> conn
          end
        else
          call(conn, "list_agents", "child-list", %{})
        end

      true ->
        send(owner, {:child_request, @child, self()})

        case AbortableHTTP.await(conn, :release_child, 10_000, owner) do
          {:released, conn} ->
            call(conn, "exec_command", "child-exec", %{
              "cmd" =>
                "printf '%s' \"$$\" > child-command.pid; read value; printf 'retained-child=%s' \"$value\"; printf '%s' \"$value\" > child-command-result",
              "login" => false,
              "yield_time_ms" => 0
            })

          {_, conn} ->
            conn
        end
    end
  end

  defp child_response(conn, @child_follow, results, owner, harness, _scenario) do
    if Map.has_key?(results, "child-stdin") do
      send(owner, {:child_stdin, results["child-stdin"]["content"]})
      answer(conn)
    else
      send(owner, {:child_request, @child_follow, self()})

      case AbortableHTTP.await(conn, :release_child, 10_000, owner) do
        {:released, conn} ->
          call(conn, "write_stdin", "child-stdin", %{
            "session_id" => Agent.get(harness.counter, & &1.command_session_id),
            "chars" => "continued\n",
            "yield_time_ms" => 1000
          })

        {_, conn} ->
          conn
      end
    end
  end

  defp call(conn, name, id, args),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
        DeterministicProvider.finish_chunk("tool_calls")
      ])

  defp answer(conn),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("child lifecycle complete"),
        DeterministicProvider.finish_chunk("stop")
      ])

  defp user_text(%{"content" => text}) when is_binary(text), do: text

  defp user_text(%{"content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)
    %{adapter: data.runtime_pid, worker: worker, manager: state.manager}
  end

  defp command_pid(ctx), do: File.read!(Path.join(ctx.harness.tmp_dir, "child-command.pid"))
  defp assert_completed, do: assert_receive({:run_event, %{type: "session.completed"}}, 15_000)
  defp eventually(check, remaining \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, remaining) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          eventually(check, remaining - 1)
        )
  end
end
