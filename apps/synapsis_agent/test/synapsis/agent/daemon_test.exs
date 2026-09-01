defmodule Synapsis.Agent.DaemonTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Runs

  defmodule ScanFailingKV do
    def put(key, value), do: Concord.Turso.put(key, value)
    def put_if(key, value, opts), do: Concord.Turso.put_if(key, value, opts)
    def get(key), do: Concord.Turso.get(key)
    def prefix_scan(_prefix), do: {:error, :store_unavailable}
  end

  defmodule SelectivePutIfKV do
    def put(key, value), do: Concord.Turso.put(key, value)
    def get(key), do: Concord.Turso.get(key)
    def prefix_scan(prefix), do: Concord.Turso.prefix_scan(prefix)

    def put_if(key, value, opts) do
      failures = Application.get_env(:synapsis_agent, :daemon_selective_put_if, [])
      run_id = key |> String.split("/") |> List.last()
      status = Map.get(value, :status) || Map.get(value, "status")

      if {run_id, status} in failures do
        {:error, String.duplicate("store failure ", 100)}
      else
        Concord.Turso.put_if(key, value, opts)
      end
    end
  end

  defmodule BlockingRuns do
    alias Synapsis.Agent.Runs

    def create(attrs) do
      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
      send(owner, {:blocking_store, self()})

      receive do
        :release_store -> Runs.create(attrs)
      end
    end

    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs
    defdelegate list_by_status_result(status, opts), to: Runs
  end

  defmodule SlowFirstRuns do
    alias Synapsis.Agent.Runs

    def create(%{prompt: "slow first"} = attrs) do
      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
      send(owner, {:slow_submit, self()})

      receive do
        :release_slow_submit -> Runs.create(attrs)
      end
    end

    def create(attrs) do
      result = Runs.create(attrs)
      send(Application.fetch_env!(:synapsis_agent, :daemon_test_owner), {:fast_submit, result})
      result
    end

    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs
    defdelegate list_by_status_result(status, opts), to: Runs
  end

  defmodule KillAfterCreateRuns do
    alias Synapsis.Agent.Runs

    def create(attrs) do
      {:ok, run} = result = Runs.create(attrs)

      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:submit_created, self(), run}
      )

      receive do
        :never -> result
      end
    end

    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs
    defdelegate list_by_status_result(status, opts), to: Runs
  end

  defmodule ReconcileFaultRuns do
    alias Synapsis.Agent.Runs

    def create(%{prompt: "reconcile with repeated faults"} = attrs) do
      {:ok, run} = result = Runs.create(attrs)
      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
      send(owner, {:submit_created, self(), run})

      receive do
        :never -> result
      end
    end

    def create(attrs) do
      result = Runs.create(attrs)
      send(Application.fetch_env!(:synapsis_agent, :daemon_test_owner), {:later_submit, result})
      result
    end

    def fetch(id) do
      agent = Application.fetch_env!(:synapsis_agent, :daemon_reconcile_fault_agent)
      attempt = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})
      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)

      case attempt do
        1 ->
          send(owner, {:reconcile_read, self(), id})

          receive do
            :never -> Runs.fetch(id)
          end

        2 ->
          send(owner, {:reconcile_read_failed, id})
          {:error, :store_unavailable}

        _attempt ->
          Runs.fetch(id)
      end
    end

    defdelegate get(id), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs
    defdelegate list_by_status_result(status, opts), to: Runs
  end

  defmodule RecoveryFaultRuns do
    alias Synapsis.Agent.Runs

    def list_by_status_result(status, opts) do
      agent = Application.fetch_env!(:synapsis_agent, :daemon_recovery_fault_agent)

      fail? =
        Agent.get_and_update(agent, fn state ->
          remaining = get_in(state, [:scan, status]) || 0
          {remaining > 0, put_in(state, [:scan, status], max(remaining - 1, 0))}
        end)

      if fail? do
        send(Application.fetch_env!(:synapsis_agent, :daemon_test_owner), {:scan_failed, status})
        {:error, {String.to_atom(status), :scan_failed}}
      else
        Runs.list_by_status_result(status, opts)
      end
    end

    def mark_interrupted(run, reason) do
      agent = Application.fetch_env!(:synapsis_agent, :daemon_recovery_fault_agent)

      fail? =
        Agent.get_and_update(agent, fn state ->
          remaining = get_in(state, [:interrupt, run.id]) || 0
          {remaining > 0, put_in(state, [:interrupt, run.id], max(remaining - 1, 0))}
        end)

      if fail? do
        send(
          Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
          {:interrupt_failed, run.id}
        )

        {:error, :interrupt_failed}
      else
        Runs.mark_interrupted(run, reason)
      end
    end

    defdelegate create(attrs), to: Runs
    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
  end

  defmodule BlockingRefillRuns do
    alias Synapsis.Agent.Runs

    def list_by_status_result("queued" = status, opts) do
      agent = Application.fetch_env!(:synapsis_agent, :daemon_refill_scan_agent)
      attempt = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})

      if attempt == 2 do
        owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
        send(owner, {:refill_scan, self()})

        receive do
          :release_refill -> Runs.list_by_status_result(status, opts)
        end
      else
        Runs.list_by_status_result(status, opts)
      end
    end

    def list_by_status_result(status, opts), do: Runs.list_by_status_result(status, opts)
    defdelegate create(attrs), to: Runs
    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs
  end

  defmodule MarkRunningFailRuns do
    alias Synapsis.Agent.Runs

    defdelegate create(attrs), to: Runs
    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs

    def mark_running(_run, _attrs) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:mark_running_failed, self()}
      )

      {:error, :mark_running_failed}
    end

    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs
    defdelegate list_by_status_result(status, opts), to: Runs
  end

  defmodule BlockingRunEvents do
    alias Synapsis.Agent.RunEvents

    for {function, delegate} <- [
          append_run_created: :append_run_created,
          append_run_started: :append_run_started,
          append_run_completed: :append_run_completed,
          append_run_failed: :append_run_failed,
          append_run_cancelled: :append_run_cancelled,
          append_run_interrupted: :append_run_interrupted
        ] do
      def unquote(function)(run) do
        maybe_block(unquote(function))
        apply(RunEvents, unquote(delegate), [run])
      end
    end

    defp maybe_block(event) do
      if Application.get_env(:synapsis_agent, :daemon_block_event) == event do
        owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
        send(owner, {:blocking_event, event, self()})

        receive do
          :release_event -> :ok
        end
      end
    end
  end

  defmodule FailingTerminalRunEvents do
    alias Synapsis.Agent.RunEvents

    def append_run_completed(_run),
      do: {:error, String.duplicate("terminal event failure ", 100)}

    defdelegate append_run_created(run), to: RunEvents
    defdelegate append_run_started(run), to: RunEvents
    defdelegate append_run_failed(run), to: RunEvents
    defdelegate append_run_cancelled(run), to: RunEvents
    defdelegate append_run_interrupted(run), to: RunEvents
  end

  defmodule FakeSessions do
    def create(_agent, _opts), do: {:ok, %{id: Ecto.UUID.generate()}}
    def get_messages(_session_id), do: []

    def cancel(session_id) do
      if Application.get_env(:synapsis_agent, :daemon_fake_session_mode) ==
           :mark_running_failure do
        send(
          Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
          {:session_cancelled, session_id}
        )
      end

      :ok
    end

    def send_message(session_id, prompt) do
      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)

      case Application.fetch_env!(:synapsis_agent, :daemon_fake_session_mode) do
        :chatty ->
          spawn(fn ->
            Enum.each(1..60, fn _index ->
              Phoenix.PubSub.broadcast(
                Synapsis.PubSub,
                "session:#{session_id}",
                {"text_delta", %{text: "."}}
              )

              Process.sleep(10)
            end)
          end)

        :controlled_done ->
          send(owner, {:controlled_session, self(), session_id})

          receive do
            :complete_session ->
              Phoenix.PubSub.broadcast(
                Synapsis.PubSub,
                "session:#{session_id}",
                {"done", %{}}
              )
          end

        :immediate_done ->
          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "session:#{session_id}",
            {"done", %{}}
          )

        :huge_error ->
          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "session:#{session_id}",
            {"error", %{message: String.duplicate("sensitive provider failure ", 100)}}
          )

        :delayed_done ->
          Process.sleep(150)

          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "session:#{session_id}",
            {"done", %{}}
          )

        :waiting ->
          send(owner, {:waiting_session, session_id})

        :ordered ->
          send(owner, {:ordered_session, prompt, self(), session_id})

          receive do
            :complete_ordered ->
              Phoenix.PubSub.broadcast(
                Synapsis.PubSub,
                "session:#{session_id}",
                {"done", %{}}
              )
          end
      end

      :ok
    end
  end

  defmodule BlockingSendSessions do
    def create(_agent, _opts), do: {:ok, %{id: Ecto.UUID.generate()}}
    def get_messages(_session_id), do: []

    def send_message(session_id, _prompt) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:blocking_send, self(), session_id}
      )

      receive do
        :release_send -> :ok
      end
    end

    def cancel(session_id) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:timeout_cancel, session_id}
      )

      :ok
    end
  end

  defmodule CleanupFailSessions do
    def create(_agent, _opts), do: {:ok, %{id: Ecto.UUID.generate()}}
    def get_messages(_session_id), do: []

    def send_message(session_id, _prompt) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:cleanup_waiting, session_id}
      )

      :ok
    end

    def cancel(session_id) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:cleanup_cancel, session_id}
      )

      {:error, String.duplicate("cleanup failure ", 100)}
    end
  end

  defmodule BlockingCancelSessions do
    def create(_agent, _opts), do: {:ok, %{id: Ecto.UUID.generate()}}
    def get_messages(_session_id), do: []

    def send_message(session_id, _prompt) do
      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
      send(owner, {:waiting_session, session_id})
      :ok
    end

    def cancel(session_id) do
      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
      send(owner, {:blocking_session_cancel, self(), session_id})

      receive do
        :release_cancel -> :ok
      end
    end
  end

  defmodule HangingTimeoutCleanupSessions do
    def create(_agent, _opts), do: {:ok, %{id: Ecto.UUID.generate()}}
    def get_messages(_session_id), do: []

    def send_message(session_id, _prompt) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:timeout_inner_blocked, self(), session_id}
      )

      receive do
        :never -> :ok
      end
    end

    def cancel(session_id) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:timeout_cleanup_blocked, self(), session_id}
      )

      receive do
        :never -> :ok
      end
    end
  end

  defmodule TerminalCountingKV do
    def put(key, value), do: Concord.Turso.put(key, value)
    def get(key), do: Concord.Turso.get(key)
    def prefix_scan(prefix), do: Concord.Turso.prefix_scan(prefix)

    def put_if(key, value, opts) do
      status = Map.get(value, :status) || Map.get(value, "status")

      if status in ~w(completed failed cancelled interrupted) do
        send(
          Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
          {:terminal_cas, key, status}
        )
      end

      Concord.Turso.put_if(key, value, opts)
    end
  end

  setup do
    Synapsis.DataCase.clear_coord("coord/agent_runs/")

    previous_owner = Application.get_env(:synapsis_agent, :daemon_test_owner, :missing)
    Application.put_env(:synapsis_agent, :daemon_test_owner, self())

    on_exit(fn ->
      restore_application_env(:daemon_test_owner, previous_owner)
      Application.delete_env(:synapsis_agent, :daemon_block_event)
      Application.delete_env(:synapsis_agent, :daemon_fake_session_mode)
      Application.delete_env(:synapsis_agent, :daemon_selective_put_if)
      Application.delete_env(:synapsis_agent, :daemon_reconcile_fault_agent)
      Application.delete_env(:synapsis_agent, :daemon_recovery_fault_agent)
      Application.delete_env(:synapsis_agent, :daemon_refill_scan_agent)
    end)

    :ok
  end

  test "starts permanently under the agent supervisor and restarts after a crash" do
    pid = Process.whereis(Daemon)
    old_task_supervisor = Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor)
    assert is_pid(pid)

    child =
      Synapsis.Agent.Supervisor
      |> Supervisor.which_children()
      |> Enum.find(fn {_id, child_pid, _type, modules} ->
        child_pid == pid and Daemon in modules
      end)

    assert {Daemon, ^pid, :worker, [Daemon]} = child

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert {:ok, restarted_pid} =
             wait_for(fn ->
               case Process.whereis(Daemon) do
                 new_pid when is_pid(new_pid) and new_pid != pid -> {:ok, new_pid}
                 _other -> :retry
               end
             end)

    assert Process.alive?(restarted_pid)

    assert {:ok, new_task_supervisor} =
             wait_for(fn ->
               case Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor) do
                 new_pid when is_pid(new_pid) and new_pid != old_task_supervisor -> {:ok, new_pid}
                 _other -> :retry
               end
             end)

    assert Process.alive?(new_task_supervisor)
    assert {:ok, %{ready: true}} = wait_for_ready()
  end

  test "reports a ready empty state without exposing prompt data" do
    assert {:ok, status} = wait_for_ready()

    assert %{
             ready: true,
             active_run: nil,
             active_run_id: nil,
             queued_count: 0,
             queued_ids: [],
             last_error: nil,
             recovery_error: nil
           } = status

    refute Map.has_key?(status, :prompt)
  end

  test "rejects blank prompts and invalid options before persistence" do
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:error, :invalid_prompt} = Daemon.submit(daemon, "  ", %{})
    assert {:error, :invalid_options} = Daemon.submit(daemon, "Do work", [])

    assert [] = Runs.list_recent()
    assert %{active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
  end

  @tag :tmp_dir
  test "runs a manual prompt through a real coding session and persists its summary", %{
    tmp_dir: tmp_dir
  } do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = register_text_provider(tmp_dir, "daemon complete")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    assert {:ok, queued} =
             Daemon.submit(daemon, "Complete the manual run", %{
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert queued.kind == "manual"
    assert queued.status == "queued"

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.queued", run_id: run_id, status: "queued"}},
                   1_000

    assert run_id == queued.id

    assert {:ok, completed} =
             wait_for(fn ->
               case Runs.get(queued.id) do
                 %{status: "completed"} = run -> {:ok, run}
                 _other -> :retry
               end
             end)

    assert completed.session_id
    assert completed.summary == "daemon complete"
    assert {:ok, %{id: session_id}} = Synapsis.Sessions.get(completed.session_id)
    assert session_id == completed.session_id

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.started", run_id: ^run_id, status: "running"}},
                   1_000

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.run.completed",
                      run_id: ^run_id,
                      status: "completed"
                    }},
                   1_000

    assert %{active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
  end

  @tag :tmp_dir
  test "marks provider failures failed and remains ready", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => %{"message" => "offline"}}))
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)

    assert {:ok, queued} =
             Daemon.submit(daemon, "Fail this run", %{
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert {:ok, failed} = wait_for_run(queued.id, "failed")
    assert failed.error =~ "offline"

    assert {:ok, %{ready: true, active_run_id: nil, queued_count: 0}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))

    assert Process.alive?(Process.whereis(daemon))
  end

  @tag :tmp_dir
  test "runs manual prompts in stable FIFO order without overlap", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    owner = self()
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:provider_request, request_number, body, self()})

      if request_number == 1 do
        receive do
          :release_first_run -> :ok
        after
          5_000 -> raise "first run was not released"
        end
      end

      send_sse(conn, [text_chunk("result #{request_number}"), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, first} = Daemon.submit(daemon, "first prompt", opts)
    assert_receive {:provider_request, 1, first_body, first_request_pid}, 2_000
    assert first_body =~ "first prompt"
    assert {:ok, first_running} = wait_for_run(first.id, "running")

    assert {:ok, second} = Daemon.submit(daemon, "second prompt", opts)
    assert {:ok, third} = Daemon.submit(daemon, "third prompt", opts)

    status = Daemon.status(daemon)
    assert %{active_run_id: first_id, queued_ids: [second_id, third_id]} = status

    assert first_id == first.id
    assert second_id == second.id
    assert third_id == third.id
    refute inspect(status) =~ "first prompt"
    refute_receive {:provider_request, 2, _body, _pid}, 200

    send(first_request_pid, :release_first_run)

    assert_receive {:provider_request, 2, second_body, _second_request_pid}, 2_000
    assert second_body =~ "second prompt"
    assert_receive {:provider_request, 3, third_body, _third_request_pid}, 2_000
    assert third_body =~ "third prompt"

    assert {:ok, first_completed} = wait_for_run(first.id, "completed")
    assert {:ok, second_completed} = wait_for_run(second.id, "completed")
    assert {:ok, third_completed} = wait_for_run(third.id, "completed")
    assert DateTime.compare(first_completed.finished_at, second_completed.started_at) != :gt
    assert DateTime.compare(second_completed.finished_at, third_completed.started_at) != :gt
    assert first_running.session_id == first_completed.session_id
  end

  @tag :tmp_dir
  test "cancelling a queued run removes it and prevents execution", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = controlled_provider(tmp_dir)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, first} = Daemon.submit(daemon, "hold first", opts)
    assert_receive {:provider_request, 1, _body, first_request_pid}, 2_000
    assert {:ok, _running} = wait_for_run(first.id, "running")
    assert {:ok, queued} = Daemon.submit(daemon, "never execute", opts)

    assert {:ok, cancelled} = Daemon.cancel(daemon, queued.id)
    assert cancelled.status == "cancelled"
    assert %{queued_ids: []} = Daemon.status(daemon)

    send(first_request_pid, :release_first_run)
    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    refute_receive {:provider_request, 2, _body, _pid}, 300
    assert %{status: "cancelled"} = Runs.get(queued.id)
  end

  @tag :tmp_dir
  test "cancelling the active run cancels its session and drains once", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = controlled_provider(tmp_dir)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, active} = Daemon.submit(daemon, "cancel active", opts)
    assert_receive {:provider_request, 1, _body, first_request_pid}, 2_000
    assert {:ok, running} = wait_for_run(active.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")

    assert {:ok, cancelled} = Daemon.cancel(daemon, active.id)
    assert cancelled.status == "cancelled"
    assert_receive {"session_status", %{status: "idle"}}, 2_000
    assert {:ok, %{status: "idle"}} = Synapsis.Sessions.get(running.session_id)
    assert %{active_run_id: nil, queued_count: 0} = Daemon.status(daemon)

    send(first_request_pid, :release_first_run)
  end

  test "cancel returns clear errors for unknown and terminal run ids" do
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:error, :not_found} = Daemon.cancel(daemon, Ecto.UUID.generate())

    assert {:ok, run} =
             Runs.create(%{
               kind: "manual",
               status: "completed",
               source: "web",
               prompt: "already done",
               tool_profile: "read_only"
             })

    assert {:error, :terminal} = Daemon.cancel(daemon, run.id)
  end

  @tag :tmp_dir
  test "queue backpressure leaves no orphan queued run", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon(queue_capacity: 1)
    {provider_name, agent_name} = controlled_provider(tmp_dir)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, first} = Daemon.submit(daemon, "first", opts)
    assert_receive {:provider_request, 1, _body, first_request_pid}, 2_000
    assert {:ok, _running} = wait_for_run(first.id, "running")
    assert {:ok, second} = Daemon.submit(daemon, "second", opts)
    assert {:error, :queue_full} = Daemon.submit(daemon, "rejected", opts)

    assert %{queued_ids: [second_id], queued_count: 1} = Daemon.status(daemon)
    assert second_id == second.id

    runs = Runs.list_recent(limit: 10)
    assert Enum.count(runs, &(&1.status == "queued")) == 1
    refute Enum.any?(runs, &(&1.prompt == "rejected" and &1.status == "queued"))

    assert {:ok, _cancelled} = Daemon.cancel(daemon, second.id)
    assert {:ok, _cancelled} = Daemon.cancel(daemon, first.id)
    send(first_request_pid, :release_first_run)
  end

  @tag :tmp_dir
  test "restart interrupts an executing run without replaying its prompt", %{tmp_dir: tmp_dir} do
    owner = self()
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:provider_request, request_number, self()})

      receive do
        :release_restart_run ->
          send_sse(conn, [text_chunk("late result"), finish_chunk("stop")])
      after
        5_000 -> Plug.Conn.send_resp(conn, 500, "timed out")
      end
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, run} = Daemon.submit("possibly executing", opts)
    assert_receive {:provider_request, 1, request_pid}, 2_000
    assert {:ok, running} = wait_for_run(run.id, "running")

    daemon_pid = Process.whereis(Daemon)
    task_supervisor_pid = Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor)
    Process.exit(daemon_pid, :kill)

    assert {:ok, restarted_pid} =
             wait_for(fn ->
               case Process.whereis(Daemon) do
                 pid when is_pid(pid) and pid != daemon_pid -> {:ok, pid}
                 _other -> :retry
               end
             end)

    assert Process.alive?(restarted_pid)

    assert {:ok, _new_task_supervisor_pid} =
             wait_for(fn ->
               case Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor) do
                 pid when is_pid(pid) and pid != task_supervisor_pid -> {:ok, pid}
                 _other -> :retry
               end
             end)

    assert {:ok, interrupted} = wait_for_run(run.id, "interrupted")
    assert interrupted.session_id == running.session_id
    assert interrupted.metadata["interruption_reason"] == "daemon_restarted"
    refute_receive {:provider_request, 2, _request_pid}, 300
    assert Agent.get(counter, & &1) == 1

    send(request_pid, :release_restart_run)
  end

  @tag :tmp_dir
  test "an abnormal run task exit fails the run and the daemon drains", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = controlled_provider(tmp_dir)

    assert {:ok, run} =
             Daemon.submit(daemon, "crash waiter", daemon_opts(agent_name, provider_name))

    assert_receive {:provider_request, 1, _body, request_pid}, 2_000
    assert {:ok, _running} = wait_for_run(run.id, "running")
    task_pid = :sys.get_state(Process.whereis(daemon)).active_run.task_pid
    Process.exit(task_pid, :kill)

    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "run task exited"
    assert %{ready: true, active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
    assert Process.alive?(Process.whereis(daemon))

    send(request_pid, :release_first_run)
  end

  test "recovery store errors remain visible without crash-looping" do
    previous = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, ScanFailingKV)

    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous) end)

    {daemon, _task_supervisor} = start_test_daemon(recover?: true)

    assert {:ok, status} =
             wait_for(fn ->
               case Daemon.status(daemon) do
                 %{ready: false, recovery_error: error} = status when is_binary(error) ->
                   {:ok, status}

                 _other ->
                   :retry
               end
             end)

    assert status.recovery_error =~ "store_unavailable"
    assert Process.alive?(Process.whereis(daemon))

    restore_application_env(:agent_runs_kv_adapter, previous)
    assert {:ok, recovered} = wait_for_status(daemon, & &1.ready)
    assert recovered.recovery_error == nil
  end

  test "all recovery scan and interrupt failures keep readiness false until retry succeeds" do
    attrs = %{
      kind: "manual",
      source: "web",
      prompt: "recover staged fault",
      tool_profile: "read_only"
    }

    assert {:ok, running} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, running} = Runs.mark_running(running)
    assert {:ok, waiting} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, waiting} = Runs.mark_running(waiting)
    assert {:ok, waiting} = Runs.mark_waiting_approval(waiting)
    assert {:ok, queued} = Runs.create(Map.put(attrs, :status, "queued"))

    {:ok, fault_agent} =
      Agent.start_link(fn ->
        %{
          scan: %{"running" => 1, "waiting_approval" => 1, "queued" => 1},
          interrupt: %{running.id => 1}
        }
      end)

    Application.put_env(:synapsis_agent, :daemon_recovery_fault_agent, fault_agent)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(recover?: true, runs: RecoveryFaultRuns, sessions: FakeSessions)

    for status <- ~w(running waiting_approval queued) do
      assert_receive {:scan_failed, ^status}, 1_000
    end

    assert {:error, :not_ready} = Daemon.submit(daemon, "must wait for scans", %{})
    assert {:ok, %{ready: false}} = wait_for_status(daemon, &(not &1.ready))

    assert_receive {:interrupt_failed, running_id}, 1_000
    assert running_id == running.id
    assert {:ok, %{ready: false}} = wait_for_status(daemon, &(not &1.ready))
    assert {:ok, _interrupted} = wait_for_run(waiting.id, "interrupted")

    assert_receive {:waiting_session, _session_id}, 2_000

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.ready and status.active_run_id == queued.id
             end)

    assert status.recovery_error == nil
    assert %{status: "interrupted"} = Runs.get(running.id)
    assert Process.alive?(Process.whereis(daemon))
  end

  @tag :tmp_dir
  test "recovery resumes never-started queued runs oldest first", %{tmp_dir: tmp_dir} do
    owner = self()
    bypass = Bypass.open()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:recovered_provider_request, body})
      send_sse(conn, [text_chunk("recovered"), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)

    attrs = %{
      kind: "manual",
      status: "queued",
      source: "web",
      assistant_name: agent_name,
      provider: provider_name,
      model: "daemon-test-model",
      tool_profile: "read_only"
    }

    assert {:ok, first} = Runs.create(Map.put(attrs, :prompt, "recover first"))
    assert {:ok, second} = Runs.create(Map.put(attrs, :prompt, "recover second"))

    {daemon, _task_supervisor} = start_test_daemon(recover?: true)

    assert_receive {:recovered_provider_request, first_body}, 2_000
    assert first_body =~ "recover first"
    assert_receive {:recovered_provider_request, second_body}, 2_000
    assert second_body =~ "recover second"
    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    assert {:ok, _completed} = wait_for_run(second.id, "completed")
    assert %{ready: true, active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
  end

  test "status stays responsive while submission persistence is blocked" do
    {daemon, _task_supervisor} = start_test_daemon(runs: BlockingRuns)
    submit_task = Task.async(fn -> Daemon.submit(daemon, "blocked submit", %{}) end)

    assert_receive {:blocking_store, store_task}, 1_000
    status_task = Task.async(fn -> Daemon.status(daemon) end)
    status_result = Task.yield(status_task, 200)
    send(store_task, :release_store)

    assert {:ok, %{ready: true}} = status_result
    assert {:ok, _run} = Task.await(submit_task, 2_000)
  end

  test "status stays responsive while session cancellation is blocked" do
    {daemon, _task_supervisor} = start_test_daemon(sessions: BlockingCancelSessions)
    assert {:ok, run} = Daemon.submit(daemon, "wait for cancel", %{})
    assert_receive {:waiting_session, session_id}, 1_000
    assert {:ok, running} = wait_for_run(run.id, "running")
    assert running.session_id == session_id

    cancel_task = Task.async(fn -> Daemon.cancel(daemon, run.id) end)
    assert_receive {:blocking_session_cancel, cancel_worker, ^session_id}, 1_000
    status_task = Task.async(fn -> Daemon.status(daemon) end)
    status_result = Task.yield(status_task, 200)
    send(cancel_worker, :release_cancel)

    assert {:ok, %{active_run_id: run_id}} = status_result
    assert run_id == run.id
    assert {:ok, %{status: "cancelled"}} = Task.await(cancel_task, 2_000)
  end

  test "status stays responsive until terminal event append completes" do
    Application.put_env(:synapsis_agent, :daemon_block_event, :append_run_completed)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)

    {daemon, _task_supervisor} =
      start_test_daemon(sessions: FakeSessions, run_events: BlockingRunEvents)

    assert {:ok, run} = Daemon.submit(daemon, "finish outside callback", %{})
    assert_receive {:blocking_event, :append_run_completed, event_task}, 1_000
    status_task = Task.async(fn -> Daemon.status(daemon) end)
    status_result = Task.yield(status_task, 200)
    send(event_task, :release_event)

    assert {:ok, %{active_run_id: run_id}} = status_result
    assert run_id == run.id
    assert {:ok, _completed} = wait_for_run(run.id, "completed")
    assert {:ok, %{active_run_id: nil}} = wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "chatty session events do not reset the absolute run timeout" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :chatty)
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions, run_timeout: 100)
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, run} = Daemon.submit(daemon, "time out absolutely", %{})
    assert {:ok, failed} = wait_for_run(run.id, "failed")

    assert failed.error =~ "session_timeout"
    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  test "absolute run timeout includes time spent sending the prompt" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :delayed_done)
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions, run_timeout: 50)

    assert {:ok, run} = Daemon.submit(daemon, "slow send", %{})
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "session_timeout"
  end

  test "completion at the absolute deadline has one terminal CAS and never crashes the daemon" do
    previous_adapter = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, TerminalCountingKV)
    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous_adapter) end)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)

    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions, run_timeout: 0)
    daemon_pid = Process.whereis(daemon)
    assert {:ok, run} = Daemon.submit(daemon, "deadline completion race", %{})

    assert {:ok, terminal} =
             wait_for(fn ->
               case Runs.get(run.id) do
                 %{status: status} = terminal when status in ~w(completed failed) ->
                   {:ok, terminal}

                 _other ->
                   :retry
               end
             end)

    assert_receive {:terminal_cas, key, terminal_status}, 1_000
    assert String.ends_with?(key, run.id)
    assert terminal_status == terminal.status
    refute_receive {:terminal_cas, ^key, _losing_status}, 150
    assert Process.whereis(daemon) == daemon_pid
    assert Process.alive?(daemon_pid)
    assert {:ok, %{active_run_id: nil}} = wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "terminal persistence failure retains degraded active ownership and does not drain" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)
    previous_adapter = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, SelectivePutIfKV)
    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous_adapter) end)

    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions)
    assert {:ok, first} = Daemon.submit(daemon, "cannot finalize", %{})
    assert_receive {:controlled_session, runner, _session_id}, 1_000
    assert {:ok, _running} = wait_for_run(first.id, "running")

    Application.put_env(
      :synapsis_agent,
      :daemon_selective_put_if,
      [{first.id, "completed"}]
    )

    send(runner, :complete_session)

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.active_run_id == first.id and status.active_run.degraded == true
             end)

    assert status.last_error =~ "store failure"
    assert String.length(status.last_error) <= 500
    assert %{status: "running"} = Runs.get(first.id)

    assert {:ok, second} = Daemon.submit(daemon, "must remain queued", %{})
    assert %{active_run_id: first_id, queued_ids: [second_id]} = Daemon.status(daemon)
    assert first_id == first.id
    assert second_id == second.id
    assert %{status: "queued"} = Runs.get(second.id)
  end

  test "partial recovery still interrupts waiting runs and owns every queued run" do
    previous_adapter = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, SelectivePutIfKV)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous_adapter) end)

    attrs = %{
      kind: "manual",
      source: "web",
      prompt: "recover",
      tool_profile: "read_only"
    }

    assert {:ok, running} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, running} = Runs.mark_running(running)
    assert {:ok, waiting} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, waiting} = Runs.mark_running(waiting)
    assert {:ok, waiting} = Runs.mark_waiting_approval(waiting)
    assert {:ok, queued} = Runs.create(Map.put(attrs, :status, "queued"))

    Application.put_env(
      :synapsis_agent,
      :daemon_selective_put_if,
      [{running.id, "interrupted"}]
    )

    {daemon, _task_supervisor} =
      start_test_daemon(recover?: true, sessions: FakeSessions, queue_capacity: 1)

    assert {:ok, blocked} =
             wait_for_status(daemon, fn status ->
               not status.ready and is_binary(status.recovery_error)
             end)

    assert blocked.recovery_error =~ "store failure"
    assert %{status: "running"} = Runs.get(running.id)
    assert %{status: "interrupted"} = Runs.get(waiting.id)

    Application.put_env(:synapsis_agent, :daemon_selective_put_if, [])
    assert_receive {:waiting_session, _session_id}, 2_000

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.ready and status.active_run_id == queued.id
             end)

    assert status.recovery_error == nil
    assert %{status: "interrupted"} = Runs.get(running.id)
    assert %{status: "running"} = Runs.get(queued.id)
  end

  test "recovery owns queued overflow instead of dropping durable runs" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :ordered)

    attrs = %{
      kind: "manual",
      status: "queued",
      source: "web",
      prompt: "overflow",
      tool_profile: "read_only"
    }

    assert {:ok, first} = Runs.create(Map.put(attrs, :prompt, "first"))
    assert {:ok, second} = Runs.create(Map.put(attrs, :prompt, "second"))
    assert {:ok, third} = Runs.create(Map.put(attrs, :prompt, "third"))

    {daemon, _task_supervisor} =
      start_test_daemon(recover?: true, sessions: FakeSessions, queue_capacity: 1)

    assert_receive {:ordered_session, "first", first_runner, _session_id}, 1_000

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.active_run_id == first.id and status.queued_count == 1
             end)

    assert status.queued_ids == [second.id]
    assert status.recovery_backlog_count == 1
    assert {:error, :queue_full} = Daemon.submit(daemon, "new work", %{})

    send(first_runner, :complete_ordered)
    assert_receive {:ordered_session, "second", second_runner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(second_runner, :complete_ordered)
    assert_receive {:ordered_session, "third", third_runner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(third_runner, :complete_ordered)

    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    assert {:ok, _completed} = wait_for_run(second.id, "completed")
    assert {:ok, _completed} = wait_for_run(third.id, "completed")

    assert {:ok, %{queued_ids: [], recovery_backlog_count: 0}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "recovery backlog rejects newer work while a free slot is being refilled" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :ordered)
    {:ok, scan_agent} = Agent.start_link(fn -> 0 end)
    Application.put_env(:synapsis_agent, :daemon_refill_scan_agent, scan_agent)

    attrs = %{
      kind: "manual",
      status: "queued",
      source: "web",
      prompt: "backlog",
      tool_profile: "read_only"
    }

    assert {:ok, _first} = Runs.create(Map.put(attrs, :prompt, "backlog first"))
    assert {:ok, second} = Runs.create(Map.put(attrs, :prompt, "backlog second"))
    assert {:ok, third} = Runs.create(Map.put(attrs, :prompt, "backlog third"))

    {daemon, _task_supervisor} =
      start_test_daemon(
        recover?: true,
        runs: BlockingRefillRuns,
        sessions: FakeSessions,
        queue_capacity: 1
      )

    assert_receive {:ordered_session, "backlog first", first_inner, _session_id}, 1_000
    assert_receive {:refill_scan, refill_task}, 1_000
    assert %{queued_ids: [], recovery_backlog_count: 2} = Daemon.status(daemon)
    assert {:error, :queue_full} = Daemon.submit(daemon, "newer work", %{})
    refute Enum.any?(Runs.list_recent(limit: 10), &(&1.prompt == "newer work"))

    send(refill_task, :release_refill)

    assert {:ok, loaded} = wait_for_status(daemon, &(&1.queued_ids == [second.id]))
    assert length(loaded.queued_ids) <= 1
    send(first_inner, :complete_ordered)

    assert_receive {:ordered_session, "backlog second", second_inner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(second_inner, :complete_ordered)

    assert_receive {:ordered_session, "backlog third", third_inner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(third_inner, :complete_ordered)
    assert {:ok, _completed} = wait_for_run(third.id, "completed")
  end

  test "rejects oversized option fields and bounds volatile errors" do
    {daemon, _task_supervisor} = start_test_daemon()
    oversized = String.duplicate("x", 256)

    for field <- ~w(assistant_name provider model source tool_profile)a do
      assert {:error, :invalid_options} =
               Daemon.submit(daemon, "bounded", %{field => oversized})
    end

    assert [] = Runs.list_recent()
  end

  test "bounds persisted, status, and event error text" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :huge_error)
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions)
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    assert {:ok, run} = Daemon.submit(daemon, "bounded failure", %{})
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert String.length(failed.error) == 500

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.run.failed",
                      run_id: run_id,
                      payload: %{error: event_error}
                    }},
                   1_000

    assert run_id == run.id
    assert String.length(event_error) == 500
    assert {:ok, status} = wait_for_status(daemon, &is_nil(&1.active_run_id))
    assert String.length(status.last_error) == 500
  end

  test "runner task start failure retains the durable queued run" do
    assert {:ok, run} =
             Runs.create(%{
               kind: "manual",
               status: "queued",
               source: "web",
               prompt: "retain me",
               tool_profile: "read_only"
             })

    state = %{
      active_run: nil,
      queue: :queue.from_list([run]),
      cancelling_ids: MapSet.new(),
      task_supervisor: :missing_daemon_task_supervisor,
      deps: %{runs: Runs, run_events: Synapsis.Agent.RunEvents, sessions: Synapsis.Sessions},
      run_timeout: 100,
      last_error: nil,
      ready: true,
      recovery_error: nil,
      queue_capacity: 1,
      pending: %{}
    }

    assert {:noreply, retained} = Daemon.handle_info(:drain, state)
    assert [retained_run] = :queue.to_list(retained.queue)
    assert retained_run.id == run.id
    assert retained.active_run == nil
    assert retained.last_error =~ "run_task_start_failed"
    assert %{status: "queued"} = Runs.get(run.id)
  end

  test "submission persistence is serialized in call order" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    {daemon, _task_supervisor} = start_test_daemon(runs: SlowFirstRuns, sessions: FakeSessions)
    {:ok, first_attrs} = Synapsis.Agent.Daemon.Execution.manual_attrs("slow first", %{})
    {:ok, second_attrs} = Synapsis.Agent.Daemon.Execution.manual_attrs("fast second", %{})
    first_ref = make_ref()
    second_ref = make_ref()
    daemon_pid = Process.whereis(daemon)

    send(daemon_pid, {:"$gen_call", {self(), first_ref}, {:submit, first_attrs}})
    assert_receive {:slow_submit, slow_task}, 1_000
    send(daemon_pid, {:"$gen_call", {self(), second_ref}, {:submit, second_attrs}})
    refute_receive {:fast_submit, _result}, 100
    refute_receive {^second_ref, _result}, 100

    send(slow_task, :release_slow_submit)
    assert_receive {^first_ref, {:ok, first_run}}, 1_000
    assert_receive {:fast_submit, {:ok, fast_run}}, 1_000
    assert_receive {^second_ref, {:ok, second_run}}, 1_000
    assert second_run.id == fast_run.id
    assert_receive {:waiting_session, _session_id}, 1_000

    assert %{active_run_id: active_id, queued_ids: [queued_id]} = Daemon.status(daemon)
    assert active_id == first_run.id
    assert queued_id == second_run.id
  end

  test "outer run task cancels a blocked send and durably times out before draining" do
    {daemon, _task_supervisor} =
      start_test_daemon(sessions: BlockingSendSessions, run_timeout: 100)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, run} = Daemon.submit(daemon, "block send", %{})
    assert_receive {:blocking_send, runner, session_id}, 1_000
    assert Process.alive?(runner)

    assert_receive {:timeout_cancel, ^session_id}, 500

    assert {:ok, failed} =
             wait_for(
               fn ->
                 case Runs.get(run.id) do
                   %{status: "failed"} = failed -> {:ok, failed}
                   _other -> :retry
                 end
               end,
               700
             )

    assert failed.error =~ "session_timeout"
    assert failed.session_id == session_id
    refute Process.alive?(runner)
    assert System.monotonic_time(:millisecond) - started_at < 700
    assert %{active_run_id: nil} = Daemon.status(daemon)
    refute_receive {:timeout_cancel, ^session_id}, 150
  end

  test "hung timeout cleanup cannot delay inner termination or durable failure" do
    {daemon, _task_supervisor} =
      start_test_daemon(
        sessions: HangingTimeoutCleanupSessions,
        run_timeout: 50,
        cleanup_timeout: 50
      )

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, run} = Daemon.submit(daemon, "bounded timeout cleanup", %{})
    assert_receive {:timeout_inner_blocked, inner, session_id}, 1_000
    assert_receive {:timeout_cleanup_blocked, cleanup, ^session_id}, 500

    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "session_timeout"
    assert failed.session_id == session_id
    refute Process.alive?(inner)
    refute Process.alive?(cleanup)
    assert System.monotonic_time(:millisecond) - started_at < 500

    assert {:ok, status} = wait_for_status(daemon, &is_nil(&1.active_run_id))
    assert status.last_error =~ "cleanup_timeout"
  end

  test "mark_running failure retains and cancels the volatile created session" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :mark_running_failure)

    {daemon, _task_supervisor} =
      start_test_daemon(runs: MarkRunningFailRuns, sessions: FakeSessions)

    assert {:ok, run} = Daemon.submit(daemon, "fail after create", %{})
    assert_receive {:mark_running_failed, inner}, 1_000
    assert_receive {:session_cancelled, session_id}, 1_000
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.session_id == session_id
    assert failed.error =~ "mark_running_failed"
    refute Process.alive?(inner)
    assert %{active_run_id: nil} = Daemon.status(daemon)
  end

  test "durable completion drains even when terminal event append fails" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)

    {daemon, _task_supervisor} =
      start_test_daemon(sessions: FakeSessions, run_events: FailingTerminalRunEvents)

    assert {:ok, first} = Daemon.submit(daemon, "first terminal event failure", %{})
    assert_receive {:controlled_session, first_runner, _session_id}, 1_000
    assert {:ok, second} = Daemon.submit(daemon, "second still drains", %{})
    send(first_runner, :complete_session)

    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    assert_receive {:controlled_session, second_runner, _session_id}, 1_000

    status = Daemon.status(daemon)
    assert status.active_run_id == second.id
    assert status.last_error =~ "terminal event failure"
    assert String.length(status.last_error) <= 500
    send(second_runner, :complete_session)
  end

  test "durable active cancel drains despite session cleanup failure" do
    {daemon, _task_supervisor} = start_test_daemon(sessions: CleanupFailSessions)
    assert {:ok, run} = Daemon.submit(daemon, "cancel cleanup failure", %{})
    assert_receive {:cleanup_waiting, session_id}, 1_000
    assert {:ok, _running} = wait_for_run(run.id, "running")
    assert {:ok, second} = Daemon.submit(daemon, "runs after cleanup failure", %{})
    runner = :sys.get_state(Process.whereis(daemon)).active_run.task_pid

    assert {:ok, cancelled} = Daemon.cancel(daemon, run.id)
    assert cancelled.status == "cancelled"
    assert_receive {:cleanup_cancel, ^session_id}, 1_000
    refute Process.alive?(runner)
    assert %{last_error: error} = Daemon.status(daemon)
    assert error =~ "cleanup failure"
    assert String.length(error) <= 500

    assert_receive {:cleanup_waiting, _second_session_id}, 1_000
    assert {:ok, status} = wait_for_status(daemon, &(&1.active_run_id == second.id))
    assert status.queued_ids == []
  end

  test "submit task death after create reconciles the pre-generated durable run" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(runs: KillAfterCreateRuns, sessions: FakeSessions)

    caller = Task.async(fn -> Daemon.submit(daemon, "reconcile created run", %{}) end)
    assert_receive {:submit_created, submit_task, created}, 1_000
    Process.exit(submit_task, :kill)

    assert {:ok, reconciled} = Task.await(caller, 2_000)
    assert reconciled.id == created.id
    assert_receive {:waiting_session, session_id}, 1_000
    assert {:ok, running} = wait_for_run(created.id, "running")
    assert running.session_id == session_id
    assert Daemon.status(daemon).active_run_id == created.id
  end

  test "submit and reconciliation task deaths plus transient reads preserve FIFO" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    {:ok, fault_agent} = Agent.start_link(fn -> 0 end)
    Application.put_env(:synapsis_agent, :daemon_reconcile_fault_agent, fault_agent)

    {daemon, _task_supervisor} =
      start_test_daemon(runs: ReconcileFaultRuns, sessions: FakeSessions)

    first_caller =
      Task.async(fn -> Daemon.submit(daemon, "reconcile with repeated faults", %{}) end)

    assert_receive {:submit_created, submit_task, created}, 1_000
    second_caller = Task.async(fn -> Daemon.submit(daemon, "later submission", %{}) end)
    Process.exit(submit_task, :kill)

    assert_receive {:reconcile_read, reconcile_task, run_id}, 1_000
    assert run_id == created.id
    refute_receive {:later_submit, _result}, 100
    Process.exit(reconcile_task, :kill)

    assert_receive {:reconcile_read_failed, ^run_id}, 1_000

    assert {:ok, reconciled} = Task.await(first_caller, 2_000)
    assert reconciled.id == created.id
    assert_receive {:later_submit, {:ok, later}}, 1_000
    assert {:ok, second} = Task.await(second_caller, 2_000)
    assert second.id == later.id

    assert_receive {:waiting_session, _session_id}, 1_000
    assert %{active_run_id: active_id, queued_ids: [queued_id]} = Daemon.status(daemon)
    assert active_id == created.id
    assert queued_id == later.id
    assert %{status: "running"} = Runs.get(created.id)
    assert %{status: "queued"} = Runs.get(later.id)
  end

  defp wait_for_ready do
    wait_for(fn ->
      case Daemon.status() do
        %{ready: true} = status -> {:ok, status}
        _other -> :retry
      end
    end)
  end

  defp start_test_daemon(opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    daemon = String.to_atom("daemon_test_#{suffix}")
    task_supervisor = String.to_atom("daemon_task_supervisor_test_#{suffix}")

    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {Daemon,
       [
         name: daemon,
         task_supervisor: task_supervisor,
         recover?: Keyword.get(opts, :recover?, false),
         queue_capacity: Keyword.get(opts, :queue_capacity, 10),
         run_timeout: Keyword.get(opts, :run_timeout, :timer.minutes(30)),
         cleanup_timeout: Keyword.get(opts, :cleanup_timeout, 1_000),
         runs: Keyword.get(opts, :runs, Runs),
         run_events: Keyword.get(opts, :run_events, Synapsis.Agent.RunEvents),
         sessions: Keyword.get(opts, :sessions, Synapsis.Sessions)
       ]}
    )

    {daemon, task_supervisor}
  end

  defp register_text_provider(tmp_dir, response_text) do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      send_sse(conn, [text_chunk(response_text), finish_chunk("stop")])
    end)

    register_provider_agent(tmp_dir, bypass)
  end

  defp controlled_provider(tmp_dir) do
    owner = self()
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:provider_request, request_number, body, self()})

      if request_number == 1 do
        receive do
          :release_first_run -> :ok
        after
          5_000 -> raise "first controlled run was not released"
        end
      end

      send_sse(conn, [text_chunk("result #{request_number}"), finish_chunk("stop")])
    end)

    register_provider_agent(tmp_dir, bypass)
  end

  defp register_provider_agent(tmp_dir, bypass) do
    suffix = System.unique_integer([:positive, :monotonic])
    provider_name = "daemon_provider_#{suffix}"
    agent_name = "daemon_agent_#{suffix}"

    :ok =
      Synapsis.Provider.Registry.register(provider_name, %{
        type: "openai",
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}"
      })

    assert {:ok, agent_config} =
             Synapsis.AgentConfigs.create(%{
               name: agent_name,
               label: "Daemon Test",
               provider: provider_name,
               model: "daemon-test-model",
               tools: [],
               permission_mode: "restrict",
               config: %{"workspace_path" => tmp_dir}
             })

    on_exit(fn ->
      Synapsis.Provider.Registry.unregister(provider_name)
      Synapsis.AgentConfigs.delete(agent_config)

      for %{session_id: session_id} when is_binary(session_id) <- Runs.list_recent(limit: 100) do
        Synapsis.Sessions.delete(session_id)
      end
    end)

    {provider_name, agent_name}
  end

  defp daemon_opts(agent_name, provider_name) do
    %{
      assistant_name: agent_name,
      provider: provider_name,
      model: "daemon-test-model"
    }
  end

  defp wait_for_run(run_id, status) do
    wait_for(fn ->
      case Runs.get(run_id) do
        %{status: ^status} = run -> {:ok, run}
        _other -> :retry
      end
    end)
  end

  defp wait_for_status(daemon, predicate) do
    wait_for(fn ->
      status = Daemon.status(daemon)
      if predicate.(status), do: {:ok, status}, else: :retry
    end)
  end

  defp restore_application_env(key, :missing), do: Application.delete_env(:synapsis_agent, key)
  defp restore_application_env(key, value), do: Application.put_env(:synapsis_agent, key, value)

  defp text_chunk(text) do
    %{
      "id" => "daemon-response",
      "choices" => [
        %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}
      ]
    }
  end

  defp finish_chunk(reason) do
    %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]}
  end

  defp send_sse(conn, chunks) do
    body =
      Enum.map_join(chunks, "\n\n", fn chunk -> "data: #{Jason.encode!(chunk)}" end) <>
        "\n\ndata: [DONE]\n\n"

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end

  defp wait_for(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      {:ok, _value} = result ->
        result

      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          do_wait_for(fun, deadline)
        else
          flunk("condition did not become true before timeout")
        end
    end
  end
end
