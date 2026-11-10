defmodule Synapsis.Session.StoreSessionIdsContentionFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Session.Store

  @checkout {DBConnection.ConnectionPool, :checkout, 3}
  @list {Concord.Turso, :list, 1}
  @queue_tasks Concord.Turso.ListQueue.Tasks

  test "candidate and exclusive continuation pages survive ordinary brief pool contention" do
    assert :ok = Store.ensure_started()
    suffix = Ecto.UUID.generate() |> String.replace("-", "") |> binary_part(0, 10)
    prefix = "ffffffff-ffff-ffff-ffff-" <> suffix
    [cursor, first, second, third] = Enum.map(~w(00 01 02 03), &(prefix <> &1))
    ids = [first, second, third]
    on_exit(fn -> Enum.each(ids, fn id -> assert :ok = Store.delete_session(id) end) end)

    for id <- ids, do: assert(:ok = Store.put_meta(id, %{title: "ordinary queued candidate"}))
    tasks = start_supervised!(Task.Supervisor)
    deadline = System.monotonic_time(:millisecond) + 4_000

    {page, first_calls} = contended_page(tasks, cursor, deadline)
    assert page == %{session_ids: [first], has_more: true, next_cursor: first, truncated: false}

    {next, second_calls} = contended_page(tasks, page.next_cursor, deadline)
    assert next == %{session_ids: [second], has_more: true, next_cursor: second, truncated: false}

    calls = first_calls ++ second_calls
    lists = for {:list, opts} <- calls, do: opts
    assert length(lists) == 4

    assert Enum.map(lists, &Keyword.fetch!(&1, :range)) == [
             {"sessions/" <> cursor <> "0", "sessions0"},
             {"sessions/" <> first <> "0", "sessions0"},
             {"sessions/" <> first <> "0", "sessions0"},
             {"sessions/" <> second <> "0", "sessions0"}
           ]

    timeouts = Enum.map(lists, &Keyword.fetch!(&1, :timeout))
    assert Enum.all?(timeouts, &(&1 in 1..4_000))
    assert timeouts == Enum.sort(timeouts, :desc)
    assert Enum.all?(lists, &(&1[:keys_only] == true and &1[:limit] == 1))

    checkouts = for {:checkout, _pid, opts} <- calls, do: opts
    assert checkouts != []

    for opts <- checkouts do
      assert is_integer(opts[:deadline])
      assert opts[:deadline] <= deadline + 50
      assert opts[:timeout] in 1..4_000
    end

    for {_worker, worker_calls} <- Enum.group_by(checkouts_with_pids(calls), &elem(&1, 0)) do
      deadlines = Enum.map(worker_calls, fn {_pid, opts} -> Keyword.fetch!(opts, :deadline) end)
      assert length(Enum.uniq(deadlines)) == 1
    end

    assert System.monotonic_time(:millisecond) < deadline
    for id <- ids, do: assert({:ok, %{title: "ordinary queued candidate"}} = Store.get_meta(id))
  end

  defp contended_page(tasks, cursor, deadline) do
    owner = self()
    token = make_ref()

    holder =
      Task.Supervisor.async_nolink(tasks, fn ->
        DBConnection.run(
          Concord.Turso.DB,
          fn _connection ->
            send(owner, {:connection_held, token})

            receive do
              {:release, ^token} -> :ok
            after
              5_000 -> flunk("the test connection holder did not receive its ordinary release")
            end
          end,
          timeout: 5_000
        )
      end)

    assert_receive {:connection_held, ^token}, 1_000

    request =
      Task.Supervisor.async_nolink(tasks, fn ->
        receive do
          {:start, ^token} -> Store.list_session_ids(cursor: cursor, limit: 1, deadline: deadline)
        after
          5_000 -> flunk("the test page request did not receive its start signal")
        end
      end)

    {:ok, observer} =
      Task.Supervisor.start_child(tasks, fn ->
        observe(owner, token, request.pid, MapSet.new(), false, [])
      end)

    monitor = Process.monitor(observer)
    queue_supervisor = Process.whereis(@queue_tasks)
    assert is_pid(queue_supervisor)
    Code.ensure_loaded!(DBConnection.ConnectionPool)
    :erlang.trace_pattern(@checkout, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace_pattern(@list, true, [:local])
    :erlang.trace(queue_supervisor, true, [:call, :set_on_spawn, {:tracer, observer}])
    :erlang.trace(request.pid, true, [:call, {:tracer, observer}])

    try do
      send(request.pid, {:start, token})
      assert_receive {:busy_admission, ^token, _request_or_owned_worker}, 1_000
      send(holder.pid, {:release, token})
      assert :ok = Task.await(holder, 1_000)
      result = Task.await(request, 2_000)
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      send(observer, {:collect, owner})
      assert_receive {:observed, ^token, calls}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 1_000
      assert {:ok, page} = result
      {page, calls}
    after
      send(holder.pid, {:release, token})
      :erlang.trace(queue_supervisor, false, [:call, :set_on_spawn])
      :erlang.trace_pattern(@checkout, false, [:local])
      :erlang.trace_pattern(@list, false, [:local])
      send(observer, :stop)
    end
  end

  # Passive traces synchronize on an actual busy checkout. No dependency pool
  # callback is invoked, replaced or suspended. Native queued workers monitor
  # their public caller, which distinguishes them from unrelated queue work.
  defp observe(owner, token, request, owned, notified, calls) do
    receive do
      {:trace, ^request, :call, {Concord.Turso, :list, [opts]}} ->
        observe(owner, token, request, owned, notified, [{:list, opts} | calls])

      {:trace, pid, :call, {DBConnection.ConnectionPool, :checkout, [_pool, _callers, opts]}} ->
        if pid == request or monitors_request?(pid, request) do
          observe(owner, token, request, MapSet.put(owned, pid), notified, [
            {:checkout, pid, opts} | calls
          ])
        else
          observe(owner, token, request, owned, notified, calls)
        end

      {:trace, pid, :return_from, @checkout,
       {:error,
        %DBConnection.ConnectionError{message: "connection not available and queuing is disabled"}}} ->
        if MapSet.member?(owned, pid) and not notified do
          send(owner, {:busy_admission, token, pid})
          observe(owner, token, request, owned, true, calls)
        else
          observe(owner, token, request, owned, notified, calls)
        end

      {:trace, _pid, :return_from, @checkout, _result} ->
        observe(owner, token, request, owned, notified, calls)

      {:collect, ^owner} ->
        send(owner, {:observed, token, Enum.reverse(calls)})

      :stop ->
        :ok
    end
  end

  defp checkouts_with_pids(calls),
    do: for({:checkout, pid, opts} <- calls, do: {pid, opts})

  defp monitors_request?(pid, request) do
    case Process.info(pid, :monitors) do
      {:monitors, monitors} -> {:process, request} in monitors
      nil -> false
    end
  end
end
