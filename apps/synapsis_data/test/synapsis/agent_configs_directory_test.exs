defmodule Synapsis.AgentConfigsDirectoryTest do
  use ExUnit.Case, async: false

  alias Synapsis.AgentConfigs
  alias Synapsis.Config.Store

  @moduletag :tmp_dir
  @table :synapsis_config_agent
  @supervisor Synapsis.Config.Store.Supervisor
  @child {Store.Server, :agent}
  @private "PRIVATE_DIRECTORY_SENTINEL"
  @ets_reads [
    select: 2,
    select: 3,
    lookup: 2,
    lookup_element: 3,
    lookup_element: 4,
    tab2list: 1,
    match: 2,
    match: 3,
    match_object: 2,
    match_object: 3
  ]

  setup %{tmp_dir: tmp_dir} do
    previous_dir = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "private-config")
    File.mkdir_p!(config_dir)
    File.chmod!(config_dir, 0o700)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)
    File.write!(Store.file_path(:agent), "")
    ensure_server_started()
    assert :ok = Store.reload(:agent)

    on_exit(fn ->
      ensure_server_started()

      if previous_dir,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous_dir),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      Store.reload(:agent)
    end)

    %{server: server()}
  end

  test "directory projects enabled configured identities without implying native spawn eligibility" do
    requester = put_agent("zeta", %{"label" => "Requester"})
    alpha = put_agent("alpha", %{"label" => "Alpha"})
    put_agent("disabled", %{"enabled" => false})

    assert {:ok, page} = directory("zeta")

    assert page == %{
             requester: %{id: requester["id"], name: "zeta"},
             agents: [
               %{id: alpha["id"], name: "alpha", label: "Alpha", configured: true},
               %{id: requester["id"], name: "zeta", label: "Requester", configured: true}
             ],
             count: 2,
             has_more: false,
             next_cursor: nil
           }

    for entry <- page.agents do
      assert {:ok, _} = Ecto.UUID.cast(entry.id)
      refute entry.id == entry.name
    end

    refute Map.has_key?(page, :allowAny)
    refute Map.has_key?(page, :spawn_allowed)
  end

  test "missing optional label and enabled fields retain existing Agent defaults" do
    requester = put_agent("main")
    assert {:ok, _} = Store.put(:agent, %{"id" => Ecto.UUID.generate(), "name" => "legacy"})

    assert {:ok, page} = directory("main")
    assert Enum.map(page.agents, & &1.name) == ["legacy", "main"]
    assert Enum.all?(page.agents, &(Map.keys(&1) |> Enum.sort() == [:configured, :id, :name]))
    assert page.requester == %{id: requester["id"], name: "main"}
  end

  test "healthy empty store and unknown or disabled requester have no implicit default" do
    assert {:error, :requester_unavailable} = directory("main")
    put_agent("main", %{"enabled" => false})
    put_agent("other")
    assert {:error, :requester_unavailable} = directory("main")
    assert {:error, :requester_unavailable} = directory("absent")
  end

  test "requester is checked even when its record is outside the returned page" do
    put_agent("alpha")
    requester = put_agent("zeta")

    assert {:ok, %{requester: %{id: id, name: "zeta"}, agents: [%{name: "alpha"}]}} =
             directory("zeta", limit: 1)

    assert id == requester["id"]
  end

  test "pages have stable configured-name ordering and round-trip public cursors" do
    for name <- ["zeta", "main", "beta", "alpha"], do: put_agent(name)

    assert {:ok, first} = directory("main", limit: 2)
    assert Enum.map(first.agents, & &1.name) == ["alpha", "beta"]
    assert first.count == 2
    assert first.has_more
    assert is_binary(first.next_cursor)
    assert byte_size(first.next_cursor) <= 4_096
    assert {:ok, ^first} = directory("main", limit: 2)

    assert {:ok, last} = directory("main", limit: 2, cursor: first.next_cursor)
    assert Enum.map(last.agents, & &1.name) == ["main", "zeta"]
    assert last.count == 2
    refute last.has_more
    assert last.next_cursor == nil
    assert last.requester == first.requester
  end

  test "deleting a cursor anchor produces an explicit stale-cursor error" do
    anchor = put_agent("alpha")
    put_agent("main")
    assert {:ok, %{next_cursor: cursor, has_more: true}} = directory("main", limit: 1)
    assert :ok = Store.delete(:agent, anchor["id"])
    assert {:error, :stale_cursor} = directory("main", limit: 1, cursor: cursor)
  end

  test "invalid requester and closed options fail before directory access" do
    put_agent("main")

    for requester <- [nil, :main, "", "../main", "Main", String.duplicate("a", 257)] do
      assert {:error, :invalid_input} = directory(requester)
    end

    for opts <- [
          %{},
          [limit: 0],
          [limit: 101],
          [limit: 1.0],
          [limit: nil],
          [limit: 1, limit: 2],
          [deadline: :infinity],
          [deadline: "later"],
          [requester: "other"],
          [include_disabled: true],
          [provider: "private"],
          [store: AnotherStore]
        ] do
      assert {:error, :invalid_input} = directory("main", opts)
    end

    for cursor <- ["", "native/run", Ecto.UUID.generate(), String.duplicate("x", 4_097)] do
      assert {:error, :invalid_cursor} = directory("main", cursor: cursor)
    end
  end

  test "newline-terminated requester names are rejected without prefix matching" do
    put_agent("main")
    assert {:error, :invalid_input} = directory("main\n")
  end

  for enabled <- [true, false] do
    test "newline-terminated candidate names are malformed even when enabled=#{enabled}" do
      put_agent("main")
      id = Ecto.UUID.generate()

      assert :ets.insert(@table, {
               id,
               %{id: id, name: "candidate\n", enabled: unquote(enabled)}
             })

      assert {:error, :invalid_config} = directory("main")
    end
  end

  test "missing Agent server is unavailable rather than an empty or seeded directory" do
    put_agent("main")
    assert :ok = Supervisor.terminate_child(@supervisor, @child)
    assert :ets.info(@table) == :undefined
    assert {:error, :storage_unavailable} = directory("main")
    assert :ets.info(@table) == :undefined
  end

  test "failed reload rejects stale entries and returns no parser body or private content" do
    raw = put_agent("main")
    File.write!(Store.file_path(:agent), "[[agents]]\nname = \"#{@private}\"\nid = [")
    assert {:error, {:parse_failed, _}} = Store.reload(:agent)
    assert {:ok, ^raw} = Store.get(:agent, raw["id"])
    assert {:error, :invalid_config} = directory("main")
    refute inspect(directory("main")) =~ @private

    File.write!(Store.file_path(:agent), "")
    assert :ok = Store.reload(:agent)
    assert {:error, :requester_unavailable} = directory("main")
  end

  test "unreadable reload is a sanitized failure even when old entries remain" do
    put_agent("main")
    File.rm!(Store.file_path(:agent))
    File.mkdir!(Store.file_path(:agent))
    assert {:error, {:read_failed, _}} = Store.reload(:agent)
    assert {:error, :storage_unavailable} = directory("main")
  end

  test "candidate budget counts disabled records and rejects overflow without partial success" do
    put_agent("main")

    entries =
      for n <- 1..999 do
        id = Ecto.UUID.generate()
        {id, %{id: id, name: "disabled_#{n}", enabled: false}}
      end

    assert :ets.insert(@table, entries)
    assert {:ok, %{agents: [%{name: "main"}], count: 1, has_more: false}} = directory("main")
    id = Ecto.UUID.generate()
    assert :ets.insert(@table, {id, %{id: id, name: "overflow", enabled: false}})
    assert {:error, :scan_limit} = directory("main", limit: 1)
  end

  test "default result page is bounded to one hundred enabled configurations" do
    put_agent("main")

    entries =
      for n <- 1..100 do
        id = Ecto.UUID.generate()
        {id, %{id: id, name: "agent_#{n}", enabled: true}}
      end

    assert :ets.insert(@table, entries)

    assert {:ok, %{agents: agents, count: 100, has_more: true, next_cursor: cursor}} =
             directory("main")

    assert length(agents) == 100

    assert {:ok, %{agents: [_], count: 1, has_more: false, next_cursor: nil}} =
             directory("main", cursor: cursor)
  end

  test "directory refuses results above the 64 KiB output budget" do
    put_agent("main")

    entries =
      for n <- 1..99 do
        id = Ecto.UUID.generate()
        {id, %{id: id, name: "agent_#{n}", enabled: true, label: String.duplicate("L", 800)}}
      end

    assert :ets.insert(@table, entries)
    assert {:error, :output_too_large} = directory("main", limit: 100)
    assert {:ok, page} = directory("main", limit: 1)
    assert byte_size(Jason.encode!(page)) <= 65_536
  end

  test "malformed identity metadata fails explicitly instead of silently dropping records" do
    put_agent("main")

    for changes <- [
          %{id: "not-a-config-uuid"},
          %{name: "../private"},
          %{name: "../disabled", enabled: false},
          %{name: nil},
          %{name: String.duplicate("a", 257)},
          %{enabled: "true"},
          %{enabled: nil},
          %{label: %{private: @private}}
        ] do
      id = Ecto.UUID.generate()
      raw = Map.merge(%{id: id, name: "candidate", enabled: true}, changes)
      assert :ets.insert(@table, {id, raw})
      assert {:error, :invalid_config} = directory("main")
      assert :ets.delete(@table, id)
    end
  end

  test "duplicate configured names and mismatched store UUIDs fail explicitly" do
    put_agent("main")
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    assert :ets.insert(@table, {first, %{id: first, name: "same", enabled: true}})
    assert :ets.insert(@table, {second, %{id: second, name: "same", enabled: false}})
    assert {:error, :invalid_config} = directory("main")
    assert :ets.delete(@table, first)
    assert :ets.delete(@table, second)
    assert :ets.insert(@table, {first, %{id: second, name: "candidate", enabled: true}})
    assert {:error, :invalid_config} = directory("main")
  end

  test "non-map records and absent identity fields cannot disappear from the snapshot" do
    put_agent("main")

    for raw <- [@private, %{name: "candidate", enabled: true}, %{id: Ecto.UUID.generate()}] do
      key = Ecto.UUID.generate()
      assert :ets.insert(@table, {key, raw})
      assert {:error, :invalid_config} = directory("main")
      assert :ets.delete(@table, key)
    end
  end

  test "large private fields remain in storage and never enter directory read results", ctx do
    requester = put_agent("main")
    [{id, raw}] = :ets.lookup(@table, requester["id"])
    private = String.duplicate(@private, 50_000)

    raw =
      Map.merge(raw, %{
        system_prompt: private,
        provider: @private,
        model: @private,
        tools: [@private],
        config: %{credentials: %{token: private}, unknown: %{nested: @private}}
      })

    assert :ets.insert(@table, {id, raw})
    start_ets_tracing(ctx.server)
    caller = spawn_directory("main", [], self(), :projection)
    trace_process(caller)
    send(caller, :start)
    assert_receive {:projection, {:ok, page}}, 1_000
    flush_trace(:all)
    messages = read_traces()

    assert page.requester == %{id: id, name: "main"}
    assert [%{id: ^id, name: "main", configured: true}] = page.agents
    refute :erlang.term_to_binary(page) =~ @private
    assert Enum.any?(messages, &match?({:trace, _, :return_from, {:ets, _, _}, _}, &1))

    for {:trace, _, :return_from, {:ets, _, _}, result} <- messages do
      refute :erlang.term_to_binary(result) =~ @private
    end

    assert [{^id, ^raw}] = :ets.lookup(@table, id)
  end

  test "expired deadline performs no directory reads", ctx do
    put_agent("main")
    start_ets_tracing(ctx.server)
    opts = [deadline: now() - 1]
    caller = spawn_directory("main", opts, self(), :expired)
    trace_process(caller)
    send(caller, :start)
    assert_receive {:expired, {:error, :timeout}}, 1_000
    flush_trace(:all)
    assert read_traces() == []
  end

  test "queued deadline expires before reading and remains expired after the server resumes",
       ctx do
    put_agent("main")
    start_ets_tracing(ctx.server)
    assert :ok = :sys.suspend(ctx.server)

    try do
      caller = spawn_directory("main", [deadline: now() + 150], self(), :queued)
      send(caller, :start)
      assert_receive {:queued, {:error, :timeout}}, 1_000
      assert :ok = :sys.resume(ctx.server)
      :sys.get_state(ctx.server)
      flush_trace(:all)
      assert read_traces() == []
    after
      :sys.resume(ctx.server)
    end
  end

  test "cancelled queued caller leaves no detached reader or later directory reads", ctx do
    put_agent("main")
    start_ets_tracing(ctx.server)
    assert :ok = :sys.suspend(ctx.server)

    try do
      caller = spawn_directory("main", [deadline: now() + 1_000], self(), :cancelled)
      trace_process(caller)
      :erlang.trace(caller, true, [:procs])
      monitor = Process.monitor(caller)
      send(caller, :start)
      await_queued_call(ctx.server)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000
      assert :ok = :sys.resume(ctx.server)
      :sys.get_state(ctx.server)
      flush_trace(:all)
      messages = read_traces()

      refute Enum.any?(messages, fn
               {:trace, _, :call, {:ets, _, _}} -> true
               {:trace, _, :return_from, {:ets, _, _}, _} -> true
               _ -> false
             end)

      for {:trace, _, :spawn, child, _} <- messages, do: refute(Process.alive?(child))
      refute_receive {:cancelled, _}, 20
    after
      :sys.resume(ctx.server)
    end
  end

  @tag timeout: 8_000
  test "a caller deadline cannot extend the data operation beyond five seconds", ctx do
    put_agent("main")
    assert :ok = :sys.suspend(ctx.server)

    try do
      started = now()
      caller = spawn_directory("main", [deadline: started + 60_000], self(), :capped)
      send(caller, :start)
      assert_receive {:capped, {:error, :timeout}}, 5_500
      assert now() - started < 5_500
    after
      :sys.resume(ctx.server)
    end
  end

  defp directory(requester, opts \\ []) do
    assert Code.ensure_loaded?(AgentConfigs)

    assert function_exported?(AgentConfigs, :directory, 2),
           "AgentConfigs.directory/2 has not been implemented"

    apply(AgentConfigs, :directory, [requester, opts])
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
        assert Process.alive?(pid)
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
        refute Process.alive?(pid), "terminated Agent store unexpectedly remains alive"
        assert now() < deadline, "Registry did not release the terminated Agent store"

        receive do
        after
          5 -> await_registry_release(deadline)
        end
    end
  end

  defp spawn_directory(requester, opts, owner, tag) do
    spawn(fn ->
      receive do
        :start -> send(owner, {tag, directory(requester, opts)})
      end
    end)
  end

  defp start_ets_tracing(server) do
    for {name, arity} <- @ets_reads do
      args = [@table | List.duplicate(:_, arity - 1)]
      :erlang.trace_pattern({:ets, name, arity}, [{args, [], [{:return_trace}]}], [])
    end

    trace_process(server)

    on_exit(fn ->
      if Process.alive?(server), do: :erlang.trace(server, false, [:call, :set_on_spawn])

      for {name, arity} <- @ets_reads,
          do: :erlang.trace_pattern({:ets, name, arity}, false, [])
    end)
  end

  defp trace_process(pid),
    do: :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, self()}])

  defp flush_trace(pid) do
    delivered = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^delivered}, 1_000
  end

  defp read_traces(acc \\ []) do
    receive do
      {:trace, _, _, _} = message -> read_traces([message | acc])
      {:trace, _, _, _, _} = message -> read_traces([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp await_queued_call(server, deadline \\ nil) do
    deadline = deadline || now() + 500
    {:messages, messages} = Process.info(server, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, _}, &1)) do
      :ok
    else
      assert now() < deadline, "directory caller did not reach the suspended config server"

      receive do
      after
        5 -> await_queued_call(server, deadline)
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
