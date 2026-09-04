defmodule Synapsis.Backplane.StartupRefreshTest do
  use ExUnit.Case, async: true

  alias Synapsis.Backplane.{Connection, StartupRefresh}

  test "schedules exactly one supervised task for each enabled sync-on-start connection" do
    parent = self()
    task_supervisor = start_supervised!(Task.Supervisor)
    eligible = connection!("eligible", enabled: true, sync_on_start: true)
    disabled = connection!("disabled", enabled: false, sync_on_start: true)
    opted_out = connection!("opted-out", enabled: true, sync_on_start: false)

    pid =
      start_supervised!(
        {StartupRefresh,
         name: nil,
         task_supervisor: task_supervisor,
         connections: fn -> [eligible, disabled, opted_out] end,
         refresh: fn id ->
           send(parent, {:refresh_started, id, self()})
           :ok
         end}
      )

    assert_receive {:refresh_started, eligible_id, task_pid}
    assert eligible_id == eligible.id
    assert task_pid != pid
    disabled_id = disabled.id
    opted_out_id = opted_out.id
    refute_receive {:refresh_started, ^disabled_id, _pid}
    refute_receive {:refresh_started, ^opted_out_id, _pid}

    eventually(fn -> :sys.get_state(pid).tasks == %{} end)
    assert Process.alive?(pid)
  end

  test "startup returns before connection enumeration or refresh work completes" do
    parent = self()
    task_supervisor = start_supervised!(Task.Supervisor)
    connection = connection!("non-blocking")

    started_at = System.monotonic_time(:millisecond)

    pid =
      start_supervised!(
        {StartupRefresh,
         name: nil,
         task_supervisor: task_supervisor,
         connections: fn ->
           send(parent, :enumerating)
           Process.sleep(100)
           [connection]
         end,
         refresh: fn _id -> Process.sleep(:infinity) end,
         timeout: 20}
      )

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 100
    assert_receive :enumerating
    assert Process.alive?(pid)
  end

  test "kills a hung task at the explicit timeout and removes its monitor" do
    parent = self()
    task_supervisor = start_supervised!(Task.Supervisor)
    connection = connection!("hung")

    pid =
      start_supervised!(
        {StartupRefresh,
         name: nil,
         task_supervisor: task_supervisor,
         timeout: 25,
         connections: fn -> [connection] end,
         refresh: fn id ->
           send(parent, {:hung_started, id, self()})
           Process.sleep(:infinity)
         end}
      )

    assert_receive {:hung_started, connection_id, task_pid}
    assert connection_id == connection.id
    assert task_pid in Task.Supervisor.children(task_supervisor)

    eventually(fn -> not Process.alive?(task_pid) end)
    eventually(fn -> :sys.get_state(pid).tasks == %{} end)
    assert Process.alive?(pid)
  end

  test "contains one refresh crash and still starts the other connection" do
    parent = self()
    task_supervisor = start_supervised!(Task.Supervisor)
    first = connection!("first")
    second = connection!("second")

    pid =
      start_supervised!(
        {StartupRefresh,
         name: nil,
         task_supervisor: task_supervisor,
         connections: fn -> [first, second] end,
         refresh: fn id ->
           send(parent, {:attempted, id})
           if id == first.id, do: raise("refresh failed"), else: :ok
         end}
      )

    assert_receive {:attempted, first_id}
    assert first_id == first.id
    assert_receive {:attempted, second_id}
    assert second_id == second.id

    eventually(fn -> :sys.get_state(pid).tasks == %{} end)
    assert Process.alive?(pid)
  end

  defp connection!(name, opts \\ []) do
    {:ok, connection} =
      Connection.new(%{
        name: name,
        endpoint: "https://#{name}.example.test",
        enabled: Keyword.get(opts, :enabled, true),
        sync_on_start: Keyword.get(opts, :sync_on_start, true)
      })

    connection
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: assert(fun.())
end
