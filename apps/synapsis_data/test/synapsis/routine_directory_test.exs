defmodule Synapsis.RoutineDirectoryTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.RoutineConfigs

  @moduletag :tmp_dir
  @types [:agent, :routine, :heartbeat]
  @supervisor Synapsis.Config.Store.Supervisor
  @private "PRIVATE_ROUTINE_DIRECTORY_SENTINEL"

  setup %{tmp_dir: tmp_dir} do
    previous_dir = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "private-config")
    File.mkdir_p!(config_dir)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)

    for type <- @types do
      File.write!(Store.file_path(type), "")
      ensure_server(type)
      assert :ok = Store.reload(type)
    end

    on_exit(fn ->
      for type <- @types, do: ensure_server(type)

      if previous_dir,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous_dir),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      for type <- @types, do: Store.reload(type)
    end)

    %{main: put_agent("main"), other: put_agent("other")}
  end

  test "UI-created missing routes belong to main visibility and both sources include disabled",
       ctx do
    ui = put_routine(:routine, "UI-created")
    disabled = put_routine(:routine, "Disabled", %{enabled: false, kind: "dream"})
    heartbeat = put_routine(:heartbeat, "Heartbeat", %{kind: "ignored legacy kind"})
    hidden = put_routine(:routine, "Other", %{agent_name: "other"})

    assert {:ok, page} = directory("main")
    assert page.requester == %{id: ctx.main, name: "main"}
    assert Enum.map(page.routines, & &1.id) == [disabled.id, heartbeat.id, ui.id]
    assert page.count == 3
    refute page.has_more
    assert page.next_cursor == nil
    assert Enum.find(page.routines, &(&1.id == disabled.id)).enabled == false
    assert Enum.find(page.routines, &(&1.id == heartbeat.id)).kind == "heartbeat"

    assert {:ok, %{routines: [%{id: id, agent_name: "other"}]}} = directory("other")
    assert id == hidden.id
    assert {:error, :not_found} = get_visible("other", "routine", ui.id)
    assert {:error, :not_found} = get_visible("main", "routine", hidden.id)
    assert {:error, :not_found} = get_visible("main", "routine", Ecto.UUID.generate())

    assert {:ok, %{requester: %{id: requester}, routine: %{id: ui_id}}} =
             get_visible("main", "routine", ui.id)

    assert requester == ctx.main
    assert ui_id == ui.id
  end

  test "source qualifies the same UUID and only the public contract leaves the store" do
    id = Ecto.UUID.generate()
    routine = put_routine(:routine, "Same", %{id: id})
    put_routine(:heartbeat, "Same", %{id: id})

    assert {:ok, %{routines: entries}} = directory("main")
    assert Enum.map(entries, &{&1.source, &1.id}) == [{"heartbeat", id}, {"routine", id}]

    for source <- ["routine", "heartbeat"] do
      assert {:ok, %{routine: entry}} = get_visible("main", source, id)
      assert entry.source == source

      assert Enum.sort(Map.keys(entry)) ==
               [:agent_name, :enabled, :id, :kind, :name, :schedule, :source, :timezone]

      assert entry.timezone == "Etc/UTC"
      assert entry.agent_name == "main"
    end

    assert [{^id, ^routine}] = :ets.lookup(table(:routine), id)
  end

  test "healthy empty sources stay empty and default pages contain twenty records" do
    assert {:ok, %{routines: [], count: 0, has_more: false, next_cursor: nil}} = directory("main")
    for n <- 1..21, do: put_routine(:routine, "Routine #{n}")
    assert {:ok, %{count: 20, has_more: true, next_cursor: cursor}} = directory("main")
    assert is_binary(cursor)
  end

  test "healthy stores initialized without routine or heartbeat config files stay empty" do
    for type <- [:routine, :heartbeat] do
      assert :ok = Supervisor.terminate_child(@supervisor, {Store.Server, type})
      File.rm!(Store.file_path(type))
      ensure_server(type)
      assert Process.alive?(server(type))
      refute File.exists?(Store.file_path(type))
    end

    assert {:ok, %{routines: [], count: 0, has_more: false, next_cursor: nil}} = directory("main")
    assert {:error, :not_found} = get_visible("main", "routine", Ecto.UUID.generate())
    assert {:error, :not_found} = get_visible("main", "heartbeat", Ecto.UUID.generate())

    for type <- [:routine, :heartbeat], do: refute(File.exists?(Store.file_path(type)))
  end

  test "missing optional enabled uses true while explicit malformed optional fields fail" do
    raw = put_routine(:heartbeat, "Legacy")
    replace_raw(:heartbeat, Map.delete(raw, :enabled))
    assert {:ok, %{routine: %{enabled: true}}} = get_visible("main", "heartbeat", raw.id)

    for {key, value} <- [enabled: nil, timezone: nil, agent_name: nil] do
      replace_raw(:heartbeat, Map.put(raw, key, value))
      assert {:error, :invalid_config} = directory("main")
    end
  end

  test "malformed records fail even when disabled or routed to another agent" do
    raw = put_routine(:routine, "Valid", %{enabled: false, agent_name: "other"})

    for {key, value} <- [
          id: String.upcase(raw.id),
          id: "not-a-uuid",
          name: <<255>>,
          name: String.duplicate("n", 257),
          name: "",
          kind: "unknown",
          enabled: "false",
          schedule: "",
          schedule: <<255>>,
          schedule: String.duplicate("s", 1_025),
          timezone: "",
          timezone: <<255>>,
          timezone: String.duplicate("t", 257),
          agent_name: "other\n",
          agent_name: "../other",
          agent_name: <<255>>,
          agent_name: String.duplicate("a", 257)
        ] do
      :ets.insert(table(:routine), {raw.id, Map.put(raw, key, value)})
      assert {:error, :invalid_config} = directory("main"), "accepted malformed #{key}"
      assert {:error, :invalid_config} = get_visible("main", "routine", Ecto.UUID.generate())
    end

    replace_raw(:routine, Map.delete(raw, :kind))
    assert {:error, :invalid_config} = directory("main")
  end

  test "canonical UUID inputs exact source names requester syntax and closed options are enforced" do
    raw = put_routine(:routine, "Valid")

    for requester <- [nil, :main, "", "Main", "main\n", "../main", <<255>>] do
      assert {:error, :invalid_input} = directory(requester)
      assert {:error, :invalid_input} = get_visible(requester, "routine", raw.id)
    end

    for source <- [:routine, "routines", "Routine", "heartbeat\n", nil],
        do: assert({:error, :invalid_input} = get_visible("main", source, raw.id))

    for id <- [nil, "main", "", String.upcase(raw.id), raw.id <> "\n"],
        do: assert({:error, :invalid_input} = get_visible("main", "routine", id))

    for opts <- [
          %{},
          [limit: 0],
          [limit: 101],
          [limit: nil],
          [limit: 1, limit: 2],
          [deadline: :infinity],
          [owner: "main"],
          [include_private: true]
        ] do
      assert {:error, :invalid_input} = directory("main", opts)
    end

    for opts <- [
          %{},
          [limit: 1],
          [cursor: nil],
          [deadline: :infinity],
          [deadline: now(), deadline: now()]
        ] do
      assert {:error, :invalid_input} = get_visible("main", "routine", raw.id, opts)
    end
  end

  test "requester must remain exact enabled configured identity", ctx do
    put_routine(:routine, "Visible")
    assert {:error, :requester_unavailable} = directory("missing")
    [{_, main}] = :ets.lookup(table(:agent), ctx.main)
    :ets.insert(table(:agent), {ctx.main, %{main | enabled: false}})
    assert {:error, :requester_unavailable} = directory("main")
    assert {:error, :requester_unavailable} = get_visible("main", "routine", Ecto.UUID.generate())
  end

  test "cursor anchors exact name source UUID and binds requester identity", ctx do
    alpha = put_routine(:routine, "Alpha")
    put_routine(:heartbeat, "Beta")
    put_routine(:routine, "Zeta")
    assert {:ok, first} = directory("main", limit: 1)
    assert Enum.map(first.routines, & &1.id) == [alpha.id]
    assert {:ok, second} = directory("main", limit: 1, cursor: first.next_cursor)
    assert [%{name: "Beta", source: "heartbeat"}] = second.routines

    assert {:ok, %{routines: [%{name: "Zeta"}], has_more: false, next_cursor: nil}} =
             directory("main", limit: 1, cursor: second.next_cursor)

    assert {:error, :invalid_cursor} = directory("other", cursor: first.next_cursor)
    :ets.delete(table(:agent), ctx.main)
    put_agent("main")
    assert {:error, :invalid_cursor} = directory("main", cursor: first.next_cursor)

    assert {:ok, current} = directory("main", limit: 1)
    :ets.delete(table(:routine), alpha.id)
    assert {:error, :stale_cursor} = directory("main", cursor: current.next_cursor)

    for cursor <- ["", 12, "not-a-cursor", String.duplicate("x", 4_097)] do
      assert {:error, :invalid_cursor} = directory("main", cursor: cursor)
    end
  end

  test "combined thousand candidate limit includes disabled and other routes and bounds exact get" do
    raw = put_routine(:routine, "Visible")
    for n <- 1..499, do: put_routine(:routine, "Hidden #{n}", %{agent_name: "other"})

    for n <- 1..500,
        do: put_routine(:heartbeat, "Disabled #{n}", %{enabled: false, agent_name: "other"})

    assert {:ok, %{count: 1}} = directory("main", limit: 1)
    assert {:ok, %{routine: %{id: id}}} = get_visible("main", "routine", raw.id)
    assert id == raw.id
    put_routine(:heartbeat, "Overflow", %{agent_name: "other"})
    assert {:error, :scan_limit} = directory("main", limit: 1)
    assert {:error, :scan_limit} = get_visible("main", "routine", raw.id)
  end

  test "encoded public response exceeding 64 KiB fails without truncating public fields" do
    for _ <- 1..100 do
      put_routine(:routine, String.duplicate("n", 256), %{
        schedule: String.duplicate("s", 1_024),
        timezone: String.duplicate("t", 256)
      })
    end

    assert {:error, :output_too_large} = directory("main", limit: 100)
    assert {:ok, %{routines: [%{schedule: schedule}]}} = directory("main", limit: 1)
    assert byte_size(schedule) == 1_024
  end

  for type <- @types do
    test "missing #{type} service fails explicitly without reseeding" do
      put_routine(:routine, "Visible")
      assert :ok = Supervisor.terminate_child(@supervisor, {Store.Server, unquote(type)})
      assert {:error, :storage_unavailable} = directory("main")
      assert :ets.info(table(unquote(type))) == :undefined
    end
  end

  for type <- [:routine, :heartbeat] do
    test "failed #{type} reload rejects stale cache and sanitizes parser failures" do
      raw = put_routine(unquote(type), "Visible")
      File.write!(Store.file_path(unquote(type)), "[[broken]]\nsecret = [#{@private}")
      assert {:error, {:parse_failed, _}} = Store.reload(unquote(type))
      assert [{_, ^raw}] = :ets.lookup(table(unquote(type)), raw.id)
      assert {:error, :invalid_config} = directory("main")
      refute inspect(directory("main")) =~ @private
    end
  end

  test "unreadable routine reload reports storage unavailable" do
    File.rm!(Store.file_path(:routine))
    File.mkdir!(Store.file_path(:routine))
    assert {:error, {:read_failed, _}} = Store.reload(:routine)
    assert {:error, :storage_unavailable} = directory("main")
  end

  test "private huge fields never leave the ETS projection and original records remain unchanged" do
    raw =
      put_routine(:routine, "Visible", %{
        prompt: String.duplicate(@private, 50_000),
        config: %{token: @private},
        metadata: %{owner: @private},
        last_status: @private
      })

    server = server(:routine)

    :erlang.trace_pattern(
      {:ets, :select, 3},
      [{[table(:routine), :_, :_], [], [{:return_trace}]}],
      []
    )

    :erlang.trace(server, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      if Process.alive?(server), do: :erlang.trace(server, false, [:call])
      :erlang.trace_pattern({:ets, :select, 3}, false, [])
    end)

    assert {:ok, page} = directory("main")
    refute :erlang.term_to_binary(page) =~ @private
    delivered = :erlang.trace_delivered(server)
    assert_receive {:trace_delivered, ^server, ^delivered}, 1_000
    assert_receive {:trace, ^server, :return_from, {:ets, :select, 3}, projected}, 1_000
    refute :erlang.term_to_binary(projected) =~ @private
    assert [{_, ^raw}] = :ets.lookup(table(:routine), raw.id)
  end

  test "expired deadline fails before reading either routine source" do
    assert {:error, :timeout} = directory("main", deadline: now() - 1)

    assert {:error, :timeout} =
             get_visible("main", "routine", Ecto.UUID.generate(), deadline: now() - 1)
  end

  test "queue time consumes the same deadline and caller cancellation performs no late scan" do
    raw = put_routine(:routine, "Visible")
    pid = server(:routine)
    assert :ok = :sys.suspend(pid)
    owner = self()

    try do
      caller =
        spawn(fn -> send(owner, {:queued_result, directory("main", deadline: now() + 100)}) end)

      await_queued(pid)
      assert_receive {:queued_result, {:error, :timeout}}, 1_000
      refute Process.alive?(caller)
      assert :ok = :sys.resume(pid)
      :sys.get_state(pid)
      assert [{_, ^raw}] = :ets.lookup(table(:routine), raw.id)

      assert :ok = :sys.suspend(pid)

      cancelled =
        spawn(fn ->
          send(owner, {:cancelled_result, directory("main", deadline: now() + 1_000)})
        end)

      await_queued(pid)
      monitor = Process.monitor(cancelled)
      Process.exit(cancelled, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^cancelled, :killed}, 1_000
      assert :ok = :sys.resume(pid)
      :sys.get_state(pid)
      refute_receive {:cancelled_result, _}, 20
    after
      :sys.resume(pid)
    end
  end

  test "requester disabled while a snapshot is queued cannot receive a result", ctx do
    put_routine(:routine, "Visible")
    pid = server(:routine)
    assert :ok = :sys.suspend(pid)
    owner = self()

    try do
      spawn(fn -> send(owner, {:changed_requester, directory("main")}) end)
      await_queued(pid)
      [{_, main}] = :ets.lookup(table(:agent), ctx.main)
      :ets.insert(table(:agent), {ctx.main, %{main | enabled: false}})
      assert :ok = :sys.resume(pid)
      assert_receive {:changed_requester, {:error, :requester_unavailable}}, 1_000
    after
      :sys.resume(pid)
    end
  end

  defp directory(requester, opts \\ []) do
    assert Code.ensure_loaded?(RoutineConfigs), "RoutineConfigs is not implemented"
    apply(RoutineConfigs, :directory, [requester, opts])
  end

  defp get_visible(requester, source, id, opts \\ []) do
    assert Code.ensure_loaded?(RoutineConfigs), "RoutineConfigs is not implemented"
    apply(RoutineConfigs, :get_visible, [requester, source, id, opts])
  end

  defp put_agent(name) do
    id = Ecto.UUID.generate()
    assert {:ok, _} = Store.put(:agent, %{id: id, name: name, enabled: true})
    id
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

    replace_raw(type, raw)
    raw
  end

  defp replace_raw(type, raw), do: :ets.insert(table(type), {raw.id, raw})
  defp table(type), do: :"synapsis_config_#{type}"
  defp now, do: System.monotonic_time(:millisecond)

  defp server(type) do
    [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
    pid
  end

  defp ensure_server(type) do
    child = {Store.Server, type}

    case List.keyfind(Supervisor.which_children(@supervisor), child, 0) do
      {^child, pid, _, _} when is_pid(pid) ->
        :sys.resume(pid)

      {^child, :undefined, _, _} ->
        await_release(type, now() + 1_000)
        assert {:ok, _} = Supervisor.restart_child(@supervisor, child)

      other ->
        flunk("Config child unavailable: #{inspect(other)}")
    end
  end

  defp await_release(type, deadline) do
    case Registry.lookup(Synapsis.Config.Store.Registry, type) do
      [] ->
        :ok

      [{pid, _}] ->
        refute Process.alive?(pid)
        assert now() < deadline

        receive do
        after
          5 -> await_release(type, deadline)
        end
    end
  end

  defp await_queued(pid, deadline \\ nil) do
    deadline = deadline || now() + 500
    {:messages, messages} = Process.info(pid, :messages)

    unless Enum.any?(messages, &match?({:"$gen_call", _, _}, &1)) do
      assert now() < deadline, "caller never reached suspended config server"

      receive do
      after
        5 -> await_queued(pid, deadline)
      end
    end
  end
end
