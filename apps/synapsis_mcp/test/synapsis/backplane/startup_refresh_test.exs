defmodule Synapsis.Backplane.StartupRefreshTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.{Connection, StartupRefresh, Sync}

  setup do
    Enum.each(Connection.list(), &Connection.delete/1)
    on_exit(fn -> Enum.each(Connection.list(), &Connection.delete/1) end)
    :ok
  end

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

  test "persists a timeout as degraded without discarding last-known-good state" do
    old_attempt = "2026-09-06T01:00:00Z"
    new_attempt = "2026-09-06T02:00:00Z"

    connection =
      persisted_connection!("persisted-timeout",
        status: "ready",
        stale: false,
        last_attempt_at: old_attempt,
        last_success_at: old_attempt,
        counts: %{"models" => 2},
        artifacts: %{"provider_id" => "provider-1"}
      )

    task_supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    _pid =
      start_supervised!(
        {StartupRefresh,
         name: nil,
         task_supervisor: task_supervisor,
         timeout: 100,
         connections: fn -> [connection] end,
         refresh: fn id, attempt_token ->
           Sync.run(id,
             attempt_token: attempt_token,
             now: new_attempt,
             client: fn _connection, _opts ->
               send(parent, {:timeout_attempt_started, attempt_token})
               Process.sleep(:infinity)
             end
           )
         end}
      )

    assert_receive {:timeout_attempt_started, _attempt_token}

    eventually(fn ->
      case Connection.get(connection.id) do
        {:ok, current} -> current.status == "degraded" and current.stale
        _error -> false
      end
    end)

    assert {:ok, degraded} = Connection.get(connection.id)
    assert degraded.last_attempt_at == "2026-09-06T02:00:00Z"
    assert degraded.last_success_at == "2026-09-06T01:00:00Z"
    assert degraded.last_error =~ "startup_refresh_timeout"
    assert degraded.counts == %{"models" => 2}
    assert degraded.artifacts == %{"provider_id" => "provider-1"}
  end

  test "persists an uncaught refresh exception as degraded" do
    attempt = "2026-09-06T03:00:00Z"
    connection = persisted_connection!("persisted-crash")
    task_supervisor = start_supervised!(Task.Supervisor)

    _pid =
      start_supervised!(
        {StartupRefresh,
         name: nil,
         task_supervisor: task_supervisor,
         connections: fn -> [connection] end,
         refresh: fn id, attempt_token ->
           assert {:ok, _failed} =
                    Sync.run(id,
                      attempt_token: attempt_token,
                      now: attempt,
                      client: fn _connection, _opts -> {:error, :pre_exception_failure} end
                    )

           raise "boom"
         end}
      )

    eventually(fn ->
      match?({:ok, %{status: "degraded", stale: true}}, Connection.get(connection.id))
    end)

    assert {:ok, degraded} = Connection.get(connection.id)
    assert degraded.last_error =~ "startup_refresh_exception"
  end

  test "an old timeout cannot overwrite a newer in-progress refresh failure" do
    old_attempt = "2026-09-06T04:00:00Z"
    new_attempt = "2026-09-06T05:00:00Z"

    connection =
      persisted_connection!("newer-attempt",
        status: "ready",
        stale: false,
        last_attempt_at: old_attempt,
        last_success_at: old_attempt
      )

    task_supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    fail_attempt = fn id, expected_token, reason ->
      send(parent, {:failure_waiting, self(), id, expected_token, reason})

      receive do
        :persist_failure -> Sync.fail_attempt(id, expected_token, reason)
      end
    end

    pid =
      start_supervised!(
        {StartupRefresh,
         name: nil,
         task_supervisor: task_supervisor,
         timeout: 100,
         connections: fn -> [connection] end,
         fail_attempt: fail_attempt,
         refresh: fn id, attempt_token ->
           Sync.run(id,
             attempt_token: attempt_token,
             now: old_attempt,
             client: fn _connection, _opts ->
               send(parent, {:old_attempt_started, attempt_token})
               Process.sleep(:infinity)
             end
           )
         end}
      )

    assert_receive {:old_attempt_started, old_token}

    assert_receive {:failure_waiting, failure_pid, id, ^old_token, :startup_refresh_timeout},
                   1_000

    assert id == connection.id

    new_token = Ecto.UUID.generate()

    newer =
      Task.async(fn ->
        Sync.run(connection.id,
          attempt_token: new_token,
          now: new_attempt,
          client: fn _connection, _opts ->
            send(parent, {:new_attempt_started, self()})

            receive do
              :finish_new_attempt -> {:error, :newer_attempt_failed}
            end
          end
        )
      end)

    assert_receive {:new_attempt_started, newer_pid}

    send(failure_pid, :persist_failure)
    send(newer_pid, :finish_new_attempt)

    assert {:ok, %{status: "degraded"}} = Task.await(newer)

    eventually(fn -> :sys.get_state(pid).tasks == %{} end)

    assert {:ok, failed} = Connection.get(connection.id)
    assert failed.last_attempt_at == new_attempt
    assert failed.last_success_at == old_attempt
    assert failed.last_error =~ "newer_attempt_failed"
    refute failed.last_error =~ "startup_refresh_timeout"
  end

  test "benign DOWN reasons do not persist startup failures" do
    connection = persisted_connection!("benign-down")
    parent = self()

    fail_attempt = fn id, attempt_token, reason ->
      send(parent, {:unexpected_failure, id, attempt_token, reason})
    end

    for reason <- [:normal, :shutdown, {:shutdown, :application_stop}, :noproc] do
      ref = make_ref()

      state = %{
        fail_attempt: fail_attempt,
        tasks: %{
          ref => %{
            attempt_id: Ecto.UUID.generate(),
            connection_id: connection.id,
            timer: make_ref()
          }
        }
      }

      assert {:noreply, %{tasks: %{}}} =
               StartupRefresh.handle_info({:DOWN, ref, :process, self(), reason}, state)
    end

    refute_receive {:unexpected_failure, _id, _attempt_token, _reason}
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

  defp persisted_connection!(name, attrs \\ []) do
    base = %{
      name: name,
      endpoint: "https://#{name}.example.test",
      enabled: true,
      sync_on_start: true
    }

    {:ok, connection} = Connection.create(Map.merge(base, Map.new(attrs)))
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
