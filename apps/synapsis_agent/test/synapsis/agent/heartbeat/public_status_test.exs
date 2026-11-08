defmodule Synapsis.Agent.Heartbeat.PublicStatusTest do
  use ExUnit.Case, async: false

  @moduletag :automation_status

  import ExUnit.CaptureLog

  alias Synapsis.Agent.Heartbeat.LocalScheduler

  test "initial state reports a pending last reload outcome" do
    {:ok, state} = LocalScheduler.init(scheduler_opts())
    assert_receive :tick
    assert state.reload_status == :pending

    assert {:reply, {:ok, snapshot}, ^state} =
             LocalScheduler.handle_call(
               {:public_status, now() + 1_000},
               {self(), make_ref()},
               state
             )

    assert snapshot == snapshot("pending")
  end

  test "successful empty reload reports only fixed public fields" do
    scheduler = start_scheduler()

    assert {:ok, result} = LocalScheduler.public_status(server: scheduler)
    assert result == snapshot("ok")
    assert :ok = LocalScheduler.reload(scheduler)
    assert {:ok, ^result} = LocalScheduler.public_status(server: scheduler)
    assert [] = LocalScheduler.status(scheduler)
  end

  test "public status never traverses or exposes hostile private state" do
    scheduler = start_scheduler()

    :sys.replace_state(scheduler, fn state ->
      %{
        state
        | timers: :private_timers_must_not_be_enumerated,
          configs: :private_configs_must_not_be_enumerated,
          trigger_results: %{secret_id: %{prompt: "private prompt", error: "private error"}}
      }
    end)

    assert {:ok, result} = LocalScheduler.public_status(server: scheduler)
    assert result == snapshot("ok")
  end

  for callback <- [:reload, :tick, :check_due_routines] do
    test "#{callback} failure is explicit and a later successful reload recovers" do
      callback = unquote(callback)
      loader = start_supervised!({Agent, fn -> :ok end})

      scheduler =
        start_scheduler(
          config_loader: fn ->
            case Agent.get(loader, & &1) do
              :ok -> []
              :fail -> raise "private reload failure"
            end
          end
        )

      Agent.update(loader, fn _ -> :fail end)

      capture_log(fn ->
        invoke_reload(scheduler, callback)

        assert {:ok, result} = LocalScheduler.public_status(server: scheduler)
        assert result == snapshot("failed")
      end)

      Agent.update(loader, fn _ -> :ok end)
      assert :ok = LocalScheduler.reload(scheduler)
      assert {:ok, result} = LocalScheduler.public_status(server: scheduler)
      assert result == snapshot("ok")
    end
  end

  test "closed options reject unknown, duplicated, and malformed values" do
    scheduler = start_scheduler()

    for opts <- [
          %{},
          :invalid,
          [scheduler],
          [unknown: true],
          [deadline: nil],
          [deadline: :infinity],
          [deadline: 1.0],
          [deadline: now() + 1_000, deadline: now() + 1_000],
          [server: scheduler, server: scheduler],
          [server: nil],
          [server: "private server"],
          [server: {:unexpected, scheduler}]
        ] do
      assert {:error, :invalid_input} = LocalScheduler.public_status(opts)
    end
  end

  test "an expired absolute deadline fails before contacting a missing scheduler" do
    assert {:error, :timeout} =
             LocalScheduler.public_status(server: __MODULE__, deadline: now() - 1)
  end

  test "an absent or stopped scheduler is unavailable without a healthy fallback" do
    assert {:error, :scheduler_unavailable} = LocalScheduler.public_status(server: __MODULE__)

    scheduler = start_scheduler()
    GenServer.stop(scheduler)

    assert {:error, :scheduler_unavailable} = LocalScheduler.public_status(server: scheduler)
  end

  test "a suspended scheduler returns a finite timeout" do
    scheduler = start_scheduler()
    :ok = :sys.suspend(scheduler)

    try do
      started = now()

      assert {:error, :timeout} =
               LocalScheduler.public_status(server: scheduler, deadline: started + 30)

      assert now() - started < 1_000
    after
      :ok = :sys.resume(scheduler)
    end

    assert {:ok, result} = LocalScheduler.public_status(server: scheduler)
    assert result == snapshot("ok")
  end

  test "queued reads carry a canonical absolute deadline clamped to five seconds" do
    scheduler = start_scheduler()
    :ok = :sys.suspend(scheduler)
    owner = self()
    started = now()

    {caller, monitor} =
      spawn_monitor(fn ->
        result = LocalScheduler.public_status(server: scheduler, deadline: now() + 60_000)
        send(owner, {:read_result, result})
      end)

    try do
      deadline = queued_deadline(scheduler, now() + 1_000)
      assert deadline >= started
      assert deadline <= now() + 5_000
    after
      :ok = :sys.resume(scheduler)
    end

    assert_receive {:read_result, {:ok, result}}, 1_000
    assert result == snapshot("ok")
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
  end

  test "a scheduler that crashes during a queued read is unavailable" do
    scheduler = start_scheduler()
    :ok = :sys.suspend(scheduler)
    owner = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(owner, {:read_result, LocalScheduler.public_status(server: scheduler)})
      end)

    queued_deadline(scheduler, now() + 1_000)
    Process.exit(scheduler, :kill)

    assert_receive {:read_result, {:error, :scheduler_unavailable}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
  end

  test "the callback rejects a queued read whose deadline has expired" do
    scheduler = start_scheduler()
    state = :sys.get_state(scheduler)

    assert {:reply, {:error, :timeout}, ^state} =
             LocalScheduler.handle_call({:public_status, now() - 1}, {self(), make_ref()}, state)
  end

  defp start_scheduler(opts \\ []) do
    scheduler =
      start_supervised!(%{
        id: make_ref(),
        start: {LocalScheduler, :start_link, [scheduler_opts(opts)]},
        restart: :temporary
      })

    :sys.get_state(scheduler)
    scheduler
  end

  defp scheduler_opts(opts \\ []) do
    Keyword.merge(
      [
        name: {:global, {__MODULE__, make_ref()}},
        config_loader: fn -> [] end,
        config_writer: fn _type, _attrs -> :ok end,
        reload_interval_ms: :timer.hours(1)
      ],
      opts
    )
  end

  defp invoke_reload(scheduler, :reload) do
    assert {:error, :reload_failed} = LocalScheduler.reload(scheduler)
  end

  defp invoke_reload(scheduler, callback), do: send(scheduler, callback)

  defp queued_deadline(scheduler, deadline) do
    case Process.info(scheduler, :messages) do
      {:messages, [{:"$gen_call", _from, {:public_status, queued}} | _]} ->
        queued

      _ ->
        assert now() < deadline

        receive do
        after
          1 -> queued_deadline(scheduler, deadline)
        end
    end
  end

  defp snapshot(reload_status),
    do: %{engine: "node_local", running: true, reload_status: reload_status}

  defp now, do: System.monotonic_time(:millisecond)
end
