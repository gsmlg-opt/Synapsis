defmodule Synapsis.AgentDirectoryTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfigs, AgentDirectory}
  alias Synapsis.Config.Store

  @moduletag :tmp_dir
  @table :synapsis_config_agent
  @supervisor Synapsis.Config.Store.Supervisor
  @child {Store.Server, :agent}
  @private "PRIVATE_CORE_AGENT_DIRECTORY"
  @ets_reads [select: 2, select: 3, lookup: 2, tab2list: 1, match_object: 2]

  setup %{tmp_dir: tmp_dir} do
    assert Code.ensure_loaded?(AgentDirectory),
           "configured Agent directory domain is not implemented"

    assert function_exported?(AgentDirectory, :list, 3)
    assert function_exported?(AgentDirectory, :validate, 1)

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "config")
    File.mkdir_p!(config_dir)
    File.chmod!(config_dir, 0o700)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)
    File.write!(Store.file_path(:agent), "")
    ensure_server_started()
    assert :ok = Store.reload(:agent)

    on_exit(fn ->
      ensure_server_started()

      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      # Reload treats a missing file as an error; an absent shared file means no agents.
      unless File.exists?(Store.file_path(:agent)), do: File.write!(Store.file_path(:agent), "")
      assert :ok = Store.reload(:agent)
    end)

    %{context: %{session_id: Ecto.UUID.generate(), requester_name: "main"}, server: server()}
  end

  test "public directory is the unchanged data projection rather than runtime or full config",
       ctx do
    requester = put_agent("main", %{"label" => "Main"})
    other = put_agent("alpha", %{"label" => "Alpha"})
    put_agent("disabled", %{"enabled" => false})
    [{id, raw}] = :ets.lookup(@table, requester["id"])

    assert :ets.insert(@table, {
             id,
             Map.merge(raw, %{
               system_prompt: String.duplicate(@private, 10_000),
               provider: @private,
               model: @private,
               tools: [@private],
               config: %{credentials: %{token: @private}}
             })
           })

    assert {:ok, expected} = AgentConfigs.directory("main")
    assert {:ok, ^expected} = AgentDirectory.list(%{}, ctx.context)

    assert expected == %{
             requester: %{id: requester["id"], name: "main"},
             agents: [
               %{id: other["id"], name: "alpha", label: "Alpha", configured: true},
               %{id: requester["id"], name: "main", label: "Main", configured: true}
             ],
             count: 2,
             has_more: false,
             next_cursor: nil
           }

    refute Jason.encode!(expected) =~ @private
    refute Map.has_key?(expected, :allowAny)
    refute Map.has_key?(expected, :children)
    refute Map.has_key?(expected, :spawn_allowed)
  end

  test "bounded pages preserve opaque cursors and requester outside the page", ctx do
    for name <- ["zeta", "main", "beta", "alpha"], do: put_agent(name)
    assert {:ok, first} = AgentDirectory.list(%{"limit" => 2}, ctx.context)
    assert Enum.map(first.agents, & &1.name) == ["alpha", "beta"]
    assert first.requester.name == "main"
    assert first.count == 2
    assert first.has_more
    assert is_binary(first.next_cursor) and byte_size(first.next_cursor) <= 4_096

    input = %{"limit" => 2, "cursor" => first.next_cursor}
    assert {:ok, last} = AgentDirectory.list(input, ctx.context)
    assert Enum.map(last.agents, & &1.name) == ["main", "zeta"]
    assert last.requester == first.requester
    assert last.count == 2
    refute last.has_more
    assert last.next_cursor == nil
  end

  test "core calls the bounded directory API without full config, defaults or legacy discovery",
       ctx do
    put_agent("main")

    forbidden = [
      {AgentConfigs, :list, 0},
      {AgentConfigs, :list_enabled, 0},
      {AgentConfigs, :get, 1},
      {AgentConfigs, :get_by_name, 1},
      {AgentConfigs, :default_attrs, 0},
      {AgentConfigs, :default_attrs, 1},
      {Store, :list, 1},
      {Store, :get, 2},
      {Synapsis.Tool.AgentDiscover, :execute, 2}
    ]

    functions = [{AgentConfigs, :directory, 2} | forbidden]
    for function <- functions, do: :erlang.trace_pattern(function, true, [:local])

    on_exit(fn ->
      for function <- functions, do: :erlang.trace_pattern(function, false, [:local])
    end)

    deadline = now() + 1_000
    caller = spawn_list(ctx.context, [deadline: deadline], :bounded_api)
    trace_process(caller)
    send(caller, :start)
    assert_receive {:bounded_api, {:ok, %{requester: %{name: "main"}}}}, 1_000

    assert_receive {:trace, reader, :call, {AgentConfigs, :directory, ["main", options]}}, 1_000
    assert reader != caller
    assert options[:deadline] == deadline
    assert Keyword.keys(options) -- [:limit, :cursor, :deadline] == []
    flush_traces()

    for {:trace, _, :call, {module, name, args}} <- read_traces(),
        do: refute({module, name, length(args)} in forbidden)
  end

  test "requester identity comes only from trusted configured name", ctx do
    put_agent("main")
    other = put_agent("other")
    assert {:ok, page} = AgentDirectory.list(%{}, %{ctx.context | requester_name: "other"})
    assert page.requester == %{id: other["id"], name: "other"}

    for key <- ~w(requester requester_name agent_id session_id provider root deadline run_id) do
      assert {:error, :invalid_input} = AgentDirectory.list(%{key => "other"}, ctx.context)
    end
  end

  test "validation accepts only a closed string-keyed page object", ctx do
    put_agent("main")

    for input <- [%{}, %{"limit" => 1}, %{"limit" => 100}, %{"cursor" => "opaque-cursor"}] do
      assert :ok = AgentDirectory.validate(input)
    end

    for input <- [
          nil,
          [],
          %{limit: 1},
          %{"limit" => 0},
          %{"limit" => 101},
          %{"limit" => 1.0},
          %{"limit" => nil},
          %{"cursor" => nil},
          %{"cursor" => ""},
          %{"cursor" => String.duplicate("x", 4_097)},
          %{"cursor" => <<255>>},
          %{"include_disabled" => true},
          %{"limit" => 1, :cursor => "mixed"}
        ] do
      assert {:error, :invalid_input} = AgentDirectory.validate(input)
      assert {:error, :invalid_input} = AgentDirectory.list(input, ctx.context)
    end
  end

  test "trusted context is exact and separates canonical session UUID from configured name",
       ctx do
    put_agent("main")

    for context <- [
          nil,
          %{},
          Map.put(ctx.context, :run_id, "/root/child:1"),
          Map.put(ctx.context, :config, %{token: @private}),
          Map.put(ctx.context, :provider, @private),
          %{ctx.context | session_id: "/root/child:1"},
          %{ctx.context | session_id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"},
          %{ctx.context | requester_name: ""},
          %{ctx.context | requester_name: "Main"},
          %{ctx.context | requester_name: "main\n"},
          %{ctx.context | requester_name: "../main"},
          %{ctx.context | requester_name: String.duplicate("a", 257)}
        ] do
      assert {:error, :invalid_context} = AgentDirectory.list(%{}, context)
    end
  end

  test "trusted options allow one absolute deadline and no backend or identity overrides", ctx do
    put_agent("main")

    for opts <- [
          %{},
          [deadline: :infinity],
          [deadline: "later"],
          [deadline: now() + 100, deadline: now() + 200],
          [limit: 1],
          [cursor: "opaque"],
          [requester_name: "other"],
          [store: AnotherStore],
          [timeout: 100],
          [provider: @private]
        ] do
      assert {:error, :invalid_input} = AgentDirectory.list(%{}, ctx.context, opts)
    end
  end

  test "empty, missing and disabled requester never become a default or successful emptiness",
       ctx do
    assert {:error, :requester_unavailable} = AgentDirectory.list(%{}, ctx.context)
    put_agent("other")
    assert {:error, :requester_unavailable} = AgentDirectory.list(%{}, ctx.context)
    put_agent("main", %{"enabled" => false})
    assert {:error, :requester_unavailable} = AgentDirectory.list(%{}, ctx.context)
  end

  test "missing store reports sanitized unavailability without starting or seeding it", ctx do
    put_agent("main")
    assert :ok = Supervisor.terminate_child(@supervisor, @child)
    assert {:error, :storage_unavailable} = AgentDirectory.list(%{}, ctx.context)
    assert :ets.info(@table) == :undefined
  end

  test "failed reload rejects stale config without exposing parser or credential details", ctx do
    put_agent("main")
    File.write!(Store.file_path(:agent), "[[agents]]\nname = \"#{@private}\"\nid = [")
    assert {:error, {:parse_failed, _}} = Store.reload(:agent)
    assert {:error, :invalid_config} = AgentDirectory.list(%{}, ctx.context)
    refute inspect(AgentDirectory.list(%{}, ctx.context)) =~ @private
  end

  test "invalid, foreign and stale cursors remain explicit errors", ctx do
    anchor = put_agent("alpha")
    put_agent("main")
    put_agent("other")
    assert {:error, :invalid_cursor} = AgentDirectory.list(%{"cursor" => "opaque"}, ctx.context)
    assert {:ok, first} = AgentDirectory.list(%{"limit" => 1}, ctx.context)
    input = %{"limit" => 1, "cursor" => first.next_cursor}

    assert {:error, :invalid_cursor} =
             AgentDirectory.list(input, %{ctx.context | requester_name: "other"})

    assert :ok = Store.delete(:agent, anchor["id"])
    assert {:error, :stale_cursor} = AgentDirectory.list(input, ctx.context)
  end

  test "malformed candidate identity fails without silently filtering the row", ctx do
    put_agent("main")
    id = Ecto.UUID.generate()
    assert :ets.insert(@table, {id, %{id: id, name: "bad\n", enabled: false}})
    assert {:error, :invalid_config} = AgentDirectory.list(%{}, ctx.context)
  end

  test "candidate scan counts disabled configurations and returns no partial overflow page",
       ctx do
    put_agent("main")

    entries =
      for n <- 1..1_000 do
        id = Ecto.UUID.generate()
        {id, %{id: id, name: "disabled_#{n}", enabled: false}}
      end

    assert :ets.insert(@table, entries)
    assert {:error, :scan_limit} = AgentDirectory.list(%{"limit" => 1}, ctx.context)
  end

  test "default page and serialized public output obey their independent budgets", ctx do
    put_agent("main")

    entries =
      for n <- 1..100 do
        id = Ecto.UUID.generate()
        {id, %{id: id, name: "agent_#{n}", enabled: true}}
      end

    assert :ets.insert(@table, entries)
    assert {:ok, %{count: 100, has_more: true} = page} = AgentDirectory.list(%{}, ctx.context)
    assert length(page.agents) == 100
    assert byte_size(Jason.encode!(page)) <= 65_536

    for {id, record} <- entries,
        do: assert(:ets.insert(@table, {id, Map.put(record, :label, String.duplicate("L", 800))}))

    assert {:error, :output_too_large} = AgentDirectory.list(%{}, ctx.context)
    assert {:ok, small} = AgentDirectory.list(%{"limit" => 1}, ctx.context)
    assert byte_size(Jason.encode!(small)) <= 65_536
  end

  test "expired deadline performs no storage reads", ctx do
    put_agent("main")
    trace_ets(ctx.server)
    caller = spawn_list(ctx.context, [deadline: now() - 1], :expired)
    trace_process(caller)
    send(caller, :start)
    assert_receive {:expired, {:error, :timeout}}, 1_000
    flush_traces()
    assert read_traces() == []
  end

  test "queued reader receives the same absolute deadline and performs no later reads", ctx do
    put_agent("main")
    trace_ets(ctx.server)
    assert :ok = :sys.suspend(ctx.server)

    try do
      deadline = now() + 200
      caller = spawn_list(ctx.context, [deadline: deadline], :queued)
      trace_process(caller)
      send(caller, :start)
      reader = await_queued_reader(ctx.server, "main", deadline)
      assert reader != caller
      assert_receive {:queued, {:error, :timeout}}, 1_000
      refute Process.alive?(reader)
      assert :ok = :sys.resume(ctx.server)
      :sys.get_state(ctx.server)
      flush_traces()
      assert read_traces() == []
    after
      :sys.resume(ctx.server)
    end
  end

  test "caller death terminates its linked queued reader before any later config read", ctx do
    put_agent("main")
    trace_ets(ctx.server)
    assert :ok = :sys.suspend(ctx.server)

    try do
      deadline = now() + 2_000
      caller = spawn_list(ctx.context, [deadline: deadline], :cancelled)
      trace_process(caller)
      send(caller, :start)
      reader = await_queued_reader(ctx.server, "main", deadline)
      assert reader != caller
      assert {:links, links} = Process.info(reader, :links)
      assert caller in links
      reader_monitor = Process.monitor(reader)
      caller_monitor = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _}, 1_000
      assert :ok = :sys.resume(ctx.server)
      :sys.get_state(ctx.server)
      flush_traces()
      assert read_traces() == []
      refute_receive {:cancelled, _}, 20
    after
      :sys.resume(ctx.server)
    end
  end

  @tag timeout: 8_000
  test "an oversized absolute deadline cannot extend the core operation beyond five seconds",
       ctx do
    put_agent("main")
    assert :ok = :sys.suspend(ctx.server)

    try do
      started = now()
      caller = spawn_list(ctx.context, [deadline: started + 60_000], :capped)
      send(caller, :start)
      assert_receive {:capped, {:error, :timeout}}, 5_500
      assert now() - started < 5_500
    after
      :sys.resume(ctx.server)
    end
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
          :start -> send(owner, {tag, AgentDirectory.list(%{}, context, opts)})
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

  defp trace_ets(server) do
    for {name, arity} <- @ets_reads do
      args = [@table | List.duplicate(:_, arity - 1)]
      :erlang.trace_pattern({:ets, name, arity}, [{args, [], [{:return_trace}]}], [])
    end

    trace_process(server)

    on_exit(fn ->
      if Process.alive?(server), do: :erlang.trace(server, false, [:call, :set_on_spawn])
      for {name, arity} <- @ets_reads, do: :erlang.trace_pattern({:ets, name, arity}, false, [])
    end)
  end

  defp trace_process(pid),
    do: :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, self()}])

  defp flush_traces do
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}, 1_000
  end

  defp read_traces(acc \\ []) do
    receive do
      {:trace, _, _, _} = message -> read_traces([message | acc])
      {:trace, _, _, _, _} = message -> read_traces([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
