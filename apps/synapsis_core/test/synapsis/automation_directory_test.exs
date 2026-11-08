defmodule Synapsis.AutomationDirectoryTest do
  use ExUnit.Case, async: false
  alias Synapsis.{AutomationDirectory, RoutineConfigs}
  alias Synapsis.Config.Store
  @moduletag :tmp_dir
  @supervisor Synapsis.Config.Store.Supervisor
  @child {Store.Server, :agent}
  @private "PRIVATE_AUTOMATION_DIRECTORY"

  setup %{tmp_dir: tmp_dir} do
    assert Code.ensure_loaded?(AutomationDirectory), "automation domain is not implemented"
    assert function_exported?(AutomationDirectory, :read, 3)
    assert function_exported?(AutomationDirectory, :validate, 1)

    original_sources =
      for type <- [:agent, :routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        {type, :sys.get_state(pid).load_error, :ets.tab2list(:"synapsis_config_#{type}")}
      end

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    File.mkdir_p!(tmp_dir)
    System.put_env("SYNAPSIS_CONFIG_DIR", tmp_dir)

    for type <- [:agent, :routine, :heartbeat] do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

    ensure_server_started()
    put_agent("main")
    put_agent("other")

    on_exit(fn ->
      ensure_server_started()

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

    %{context: %{session_id: Ecto.UUID.generate(), requester_name: "main"}, server: server()}
  end

  test "list and exact get pass unchanged public data through both sources and execution routes",
       ctx do
    ui = put_routine(:routine, "Alpha")
    disabled = put_routine(:heartbeat, "Beta", %{enabled: false})
    hidden = put_routine(:routine, "Other", %{agent_name: "other"})
    assert {:ok, expected} = RoutineConfigs.directory("main")
    assert {:ok, ^expected} = AutomationDirectory.read(%{"action" => "list"}, ctx.context)
    assert Enum.map(expected.routines, & &1.id) == [ui.id, disabled.id]
    refute Enum.at(expected.routines, 1).enabled
    refute Jason.encode!(expected) =~ @private

    for {source, raw} <- [{"routine", ui}, {"heartbeat", disabled}] do
      assert {:ok, expected_get} = RoutineConfigs.get_visible("main", source, raw.id)

      assert {:ok, ^expected_get} =
               AutomationDirectory.read(
                 %{"action" => "get", "source" => source, "id" => raw.id},
                 ctx.context
               )
    end

    for id <- [hidden.id, Ecto.UUID.generate()] do
      assert {:error, :not_found} =
               AutomationDirectory.read(
                 %{"action" => "get", "source" => "routine", "id" => id},
                 ctx.context
               )
    end
  end

  test "pages preserve cursor and requester with default twenty and exact source-qualified IDs",
       ctx do
    for n <- 1..21, do: put_routine(:routine, "Routine #{n}")
    assert {:ok, first} = AutomationDirectory.read(%{"action" => "list"}, ctx.context)
    assert first.count == 20
    assert first.has_more

    assert {:ok, last} =
             AutomationDirectory.read(
               %{"action" => "list", "cursor" => first.next_cursor},
               ctx.context
             )

    assert last.count == 1
    assert last.requester == first.requester
    refute last.has_more

    assert {:error, :invalid_cursor} =
             AutomationDirectory.read(%{"action" => "list", "cursor" => first.next_cursor}, %{
               ctx.context
               | requester_name: "other"
             })

    assert {:error, :invalid_cursor} =
             AutomationDirectory.read(%{"action" => "list", "cursor" => "opaque"}, ctx.context)
  end

  test "strict list and get branches reject unknown, mixed and mutation arguments", ctx do
    id = Ecto.UUID.generate()

    for input <- [
          %{"action" => "list"},
          %{"action" => "list", "limit" => 100, "cursor" => "opaque"},
          %{"action" => "get", "source" => "heartbeat", "id" => id}
        ] do
      assert :ok = AutomationDirectory.validate(input)
    end

    invalid = [
      nil,
      [],
      %{},
      %{action: "list"},
      %{"action" => "list", "limit" => 0},
      %{"action" => "list", "limit" => 101},
      %{"action" => "list", "limit" => 1.0},
      %{"action" => "list", "cursor" => nil},
      %{"action" => "list", "cursor" => ""},
      %{"action" => "list", "cursor" => <<255>>},
      %{"action" => "list", "cursor" => String.duplicate("x", 4097)},
      %{"action" => "get"},
      %{"action" => "get", "source" => "routine", "id" => String.upcase(id)},
      %{"action" => "get", "source" => "Routine", "id" => id},
      %{"action" => "list", "source" => "routine"},
      %{"action" => "list", "id" => id},
      %{"action" => "get", "source" => "routine", "id" => id, "limit" => 1},
      %{"action" => "get", "source" => "routine", "id" => id, "cursor" => "opaque"}
    ]

    invalid =
      invalid ++
        for action <- ~w(status runs add update remove run wake), do: %{"action" => action}

    invalid =
      invalid ++
        for key <-
              ~w(requester_name agent_name session_id run_id project root prompt metadata provider deadline),
            do: %{"action" => "list", key => "forged"}

    for input <- invalid do
      assert {:error, :invalid_input} = AutomationDirectory.validate(input)
      assert {:error, :invalid_input} = AutomationDirectory.read(input, ctx.context)
    end
  end

  test "trusted context and options are closed and canonical", ctx do
    for context <- [
          nil,
          %{},
          Map.put(ctx.context, :agent, %{}),
          %{ctx.context | session_id: "/root/child:1"},
          %{ctx.context | session_id: String.upcase(ctx.context.session_id)},
          %{ctx.context | requester_name: "main\n"},
          %{ctx.context | requester_name: "../main"}
        ] do
      assert {:error, :invalid_context} = AutomationDirectory.read(%{"action" => "list"}, context)
    end

    for opts <- [
          %{},
          [timeout: 1],
          [deadline: :infinity],
          [deadline: now(), deadline: now()],
          [requester_name: "other"],
          [backend: RoutineConfigs]
        ] do
      assert {:error, :invalid_input} =
               AutomationDirectory.read(%{"action" => "list"}, ctx.context, opts)
    end

    assert {:error, :timeout} =
             AutomationDirectory.read(%{"action" => "list"}, ctx.context, deadline: now() - 1)
  end

  test "missing requester and unhealthy source errors remain sanitized", ctx do
    assert {:error, :requester_unavailable} =
             AutomationDirectory.read(%{"action" => "list"}, %{
               ctx.context
               | requester_name: "missing"
             })

    File.write!(Store.file_path(:routine), "[[broken]]\nsecret = [#{@private}")
    assert {:error, {:parse_failed, _}} = Store.reload(:routine)

    assert {:error, :invalid_config} =
             AutomationDirectory.read(%{"action" => "list"}, ctx.context)

    refute inspect(AutomationDirectory.read(%{"action" => "list"}, ctx.context)) =~ @private
    assert :ok = Supervisor.terminate_child(@supervisor, @child)

    assert {:error, :storage_unavailable} =
             AutomationDirectory.read(%{"action" => "list"}, ctx.context)
  end

  test "only bounded data APIs receive one unchanged absolute deadline", ctx do
    routine = put_routine(:routine, "Visible")
    functions = [{RoutineConfigs, :directory, 2}, {RoutineConfigs, :get_visible, 4}]
    for function <- functions, do: :erlang.trace_pattern(function, true, [:local])

    on_exit(fn ->
      for function <- functions, do: :erlang.trace_pattern(function, false, [:local])
    end)

    owner = self()
    deadline = now() + 1_000

    task =
      spawn(fn ->
        receive do
          :start ->
            send(
              owner,
              {:read,
               AutomationDirectory.read(%{"action" => "list"}, ctx.context, deadline: deadline)}
            )

            send(
              owner,
              {:get,
               AutomationDirectory.read(
                 %{"action" => "get", "source" => "routine", "id" => routine.id},
                 ctx.context,
                 deadline: deadline
               )}
            )
        end
      end)

    trace_process(task)
    send(task, :start)
    assert_receive {:read, {:ok, _}}, 1_000
    assert_receive {:get, {:ok, _}}, 1_000

    assert_receive {:trace, reader, :call, {RoutineConfigs, :directory, ["main", list_opts]}},
                   1_000

    assert reader != task
    assert list_opts[:deadline] == deadline
    assert list_opts[:limit] == 20

    assert_receive {:trace, _, :call,
                    {RoutineConfigs, :get_visible, ["main", "routine", _, [deadline: ^deadline]]}},
                   1_000
  end

  test "queued reader times out and caller death terminates linked readers", ctx do
    for mode <- [:timeout, :cancel] do
      assert :ok = :sys.suspend(ctx.server)

      try do
        deadline = now() + if(mode == :timeout, do: 150, else: 1000)
        caller = spawn_list(ctx.context, [deadline: deadline], mode)
        send(caller, :start)
        reader = await_queued_reader(ctx.server, "main", deadline)
        refute reader == caller
        monitor = Process.monitor(reader)

        if mode == :timeout do
          assert_receive {:timeout, {:error, :timeout}}, 1000
        else
          Process.exit(caller, :kill)
        end

        assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 1000
      after
        :sys.resume(ctx.server)
      end
    end
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

  defp put_agent(name, attrs \\ %{}) do
    raw = Map.merge(%{"id" => Ecto.UUID.generate(), "name" => name, "enabled" => true}, attrs)
    assert {:ok, ^raw} = Store.put(:agent, raw)
    raw
  end

  defp server do
    [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, :agent)
    pid
  end

  defp ensure_server_started do
    case List.keyfind(Supervisor.which_children(@supervisor), @child, 0) do
      {@child, pid, _, _} when is_pid(pid) ->
        assert Process.alive?(pid)
        assert :ok = :sys.resume(pid)
        assert [{^pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, :agent)

      {@child, :undefined, _, _} ->
        await_registry_release(now() + 1_000)
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
        assert now() < deadline, "Registry did not release the terminated Agent store"

        receive do
        after
          5 -> await_registry_release(deadline)
        end
    end
  end

  defp spawn_list(context, opts, tag) do
    owner = self()

    pid =
      spawn(fn ->
        receive do
          :start ->
            send(owner, {tag, AutomationDirectory.read(%{"action" => "list"}, context, opts)})
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp await_queued_reader(server, requester, deadline, wait_until \\ nil) do
    wait_until = wait_until || now() + 1_000
    {:messages, messages} = Process.info(server, :messages)

    case Enum.find(messages, fn
           {:"$gen_call", _, {:agent_directory_snapshot, ^requester, ^deadline}} -> true
           _ -> false
         end) do
      {:"$gen_call", {reader, _}, _} ->
        reader

      nil ->
        assert now() < wait_until, "directory reader did not reach the suspended config server"

        receive do
        after
          5 -> await_queued_reader(server, requester, deadline, wait_until)
        end
    end
  end

  defp trace_process(pid),
    do: :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, self()}])

  defp now, do: System.monotonic_time(:millisecond)
end
