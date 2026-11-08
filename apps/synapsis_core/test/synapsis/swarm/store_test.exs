defmodule Synapsis.Swarm.StoreTest do
  use ExUnit.Case, async: false

  alias Synapsis.Swarm
  alias Synapsis.Swarm.Store

  @table :synapsis_swarm_teammates
  @supervisor SynapsisCore.Supervisor

  setup do
    assert is_pid(Process.whereis(Store))
    session = Ecto.UUID.generate()

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, session)
    end)

    %{session: session}
  end

  test "one supervised core process owns the public metadata table" do
    owner = Process.whereis(Store)
    assert :ets.info(@table, :owner) == owner
    assert :ets.info(@table, :protection) == :public
    assert {Store, owner, :worker, [Store]} in Supervisor.which_children(@supervisor)
  end

  test "owner downtime leaves domain callers unavailable and restart loses metadata",
       ctx do
    assert {:ok, _} = Swarm.teammate(ctx.session, %{"action" => "create", "name" => "ephemeral"})
    owner = Process.whereis(Store)
    stop_owner()

    assert :ets.whereis(@table) == :undefined
    assert {:error, :unavailable} = Swarm.teammate(ctx.session, %{"action" => "list"})

    assert :ets.whereis(@table) == :undefined
    assert {:ok, replacement} = Supervisor.restart_child(@supervisor, Store)
    refute replacement == owner
    assert :ets.info(@table, :owner) == replacement
    assert {:ok, []} = Swarm.teammate(ctx.session, %{"action" => "list"})
  end

  test "startup rejects unexpected ownership and domain callers cannot use a foreign table",
       ctx do
    stop_owner()
    parent = self()

    rogue =
      spawn(fn ->
        :ets.new(@table, [:named_table, :set, :public])
        send(parent, {:foreign_table, self()})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn ->
      monitor = Process.monitor(rogue)
      send(rogue, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^rogue, _}, 1_000
    end)

    assert_receive {:foreign_table, ^rogue}, 1_000

    startup =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        Store.start_link([])
      end)

    assert {:error, {:unexpected_owner, ^rogue}} = Task.await(startup)
    assert :ets.info(@table, :owner) == rogue
    assert Process.whereis(Store) == nil

    assert {:error, :unavailable} =
             Swarm.teammate(ctx.session, %{"action" => "create", "name" => "forbidden"})

    assert :ets.lookup(@table, ctx.session) == []

    monitor = Process.monitor(rogue)
    send(rogue, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^rogue, _}, 1_000
    assert {:ok, owner} = Supervisor.restart_child(@supervisor, Store)
    assert :ets.info(@table, :owner) == owner
  end

  defp stop_owner do
    assert :ok = Supervisor.terminate_child(@supervisor, Store)

    on_exit(fn ->
      if Process.whereis(Store) == nil, do: Supervisor.restart_child(@supervisor, Store)
    end)
  end
end
