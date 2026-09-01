defmodule Synapsis.Agent.DaemonCase do
  @moduledoc false

  use ExUnit.CaseTemplate
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Daemon.StatusPublisher
  alias Synapsis.Agent.Runs

  using do
    quote do
      use Synapsis.Agent.DataCase, async: false
      import Synapsis.Agent.DaemonCase
      alias Synapsis.Agent.Daemon
      alias Synapsis.Agent.Daemon.StatusPublisher
      alias Synapsis.Agent.Runs
      alias Synapsis.Agent.DaemonCase.ScanFailingKV
      alias Synapsis.Agent.DaemonCase.SelectivePutIfKV
      alias Synapsis.Agent.DaemonCase.BlockingRuns
      alias Synapsis.Agent.DaemonCase.SlowFirstRuns
      alias Synapsis.Agent.DaemonCase.KillAfterCreateRuns
      alias Synapsis.Agent.DaemonCase.ReconcileFaultRuns
      alias Synapsis.Agent.DaemonCase.RecoveryFaultRuns
      alias Synapsis.Agent.DaemonCase.BlockingRefillRuns
      alias Synapsis.Agent.DaemonCase.DeadlineRuns
      alias Synapsis.Agent.DaemonCase.DeadlinePutIfKV
      alias Synapsis.Agent.DaemonCase.MarkRunningFailRuns
      alias Synapsis.Agent.DaemonCase.BlockingRunEvents
      alias Synapsis.Agent.DaemonCase.HangingRunEvents
      alias Synapsis.Agent.DaemonCase.ControlledStatusRunEvents
      alias Synapsis.Agent.DaemonCase.FailingTerminalRunEvents
      alias Synapsis.Agent.DaemonCase.FakeSessions
      alias Synapsis.Agent.DaemonCase.BlockingSendSessions
      alias Synapsis.Agent.DaemonCase.CleanupFailSessions
      alias Synapsis.Agent.DaemonCase.BlockingCancelSessions
      alias Synapsis.Agent.DaemonCase.HangingTimeoutCleanupSessions
      alias Synapsis.Agent.DaemonCase.FirstCleanupHangsSessions
      alias Synapsis.Agent.DaemonCase.TerminalCountingKV
    end
  end

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

  defmodule DeadlineRuns do
    alias Synapsis.Agent.Runs

    def create(attrs) do
      case mode(:create) do
        :persist_then_hang ->
          {:ok, run} = result = Runs.create(attrs)
          hang(:create_after_persist, run)
          result

        :hang ->
          hang(:create, attrs)
          Runs.create(attrs)

        _other ->
          notify(:create, Map.get(attrs, :prompt))
          Runs.create(attrs)
      end
    end

    def fetch(id) do
      if mode(:fetch) == :hang do
        hang(:fetch, id)
      else
        Runs.fetch(id)
      end
    end

    def mark_cancelled(run, attrs \\ %{}) do
      if mode(:cancel) == :hang do
        hang(:cancel, run)
      else
        Runs.mark_cancelled(run, attrs)
      end
    end

    def list_by_status_result(status, opts) do
      if mode({:scan, status}) == :hang do
        hang({:scan, status}, status)
      else
        Runs.list_by_status_result(status, opts)
      end
    end

    defdelegate get(id), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, error), to: Runs
    defdelegate mark_failed(run, error, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs

    defp mode(key) do
      Agent.get(Application.fetch_env!(:synapsis_agent, :daemon_deadline_agent), fn state ->
        Map.get(state, key, :pass)
      end)
    end

    defp hang(operation, value) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:durable_operation_hung, operation, self(), value}
      )

      receive do
        :never -> :ok
      end
    end

    defp notify(operation, value) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:durable_operation_called, operation, value}
      )
    end
  end

  defmodule DeadlinePutIfKV do
    def put(key, value), do: Concord.Turso.put(key, value)
    def get(key), do: Concord.Turso.get(key)
    def prefix_scan(prefix), do: Concord.Turso.prefix_scan(prefix)

    def put_if(key, value, opts) do
      status = Map.get(value, :status) || Map.get(value, "status")
      agent = Application.fetch_env!(:synapsis_agent, :daemon_deadline_agent)

      if Agent.get(agent, &MapSet.member?(Map.get(&1, :hang_put_if, MapSet.new()), status)) do
        send(
          Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
          {:durable_operation_hung, {:put_if, status}, self(), key}
        )

        receive do
          :never -> :ok
        end
      else
        Concord.Turso.put_if(key, value, opts)
      end
    end
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

  defmodule HangingRunEvents do
    alias Synapsis.Agent.RunEvents

    for function <- [
          :append_run_created,
          :append_run_started,
          :append_run_completed,
          :append_run_failed,
          :append_run_cancelled,
          :append_run_interrupted
        ] do
      def unquote(function)(run) do
        if Application.get_env(:synapsis_agent, :daemon_hanging_event) == unquote(function) do
          owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
          send(owner, {:hanging_event, unquote(function), self(), run.id})

          receive do
            :never -> :ok
          end
        else
          apply(RunEvents, unquote(function), [run])
        end
      end
    end
  end

  defmodule ControlledStatusRunEvents do
    alias Synapsis.Agent.RunEvents

    def publish_daemon_status(status, sequence) do
      agent = Application.fetch_env!(:synapsis_agent, :daemon_status_agent)

      {attempt, mode} =
        Agent.get_and_update(agent, fn state ->
          attempt = state.attempt + 1
          {{attempt, state.mode}, %{state | attempt: attempt}}
        end)

      owner = Application.fetch_env!(:synapsis_agent, :daemon_test_owner)
      send(owner, {:status_publish_started, self(), attempt, sequence, status})

      result =
        case mode do
          :block ->
            receive do
              :release_status -> :ok
            end

          :hang ->
            receive do
              :never -> :ok
            end

          :pass ->
            :ok

          :error ->
            {:error, :status_publish_failed}
        end

      if result == :ok, do: send(owner, {:status_published, attempt, sequence, status})
      result
    end

    defdelegate append_run_created(run), to: RunEvents
    defdelegate append_run_started(run), to: RunEvents
    defdelegate append_run_completed(run), to: RunEvents
    defdelegate append_run_failed(run), to: RunEvents
    defdelegate append_run_cancelled(run), to: RunEvents
    defdelegate append_run_interrupted(run), to: RunEvents
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

  defmodule FirstCleanupHangsSessions do
    def create(_agent, _opts), do: {:ok, %{id: Ecto.UUID.generate()}}
    def get_messages(_session_id), do: []

    def send_message(session_id, _prompt) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:owner_death_inner, self(), session_id}
      )

      receive do
        :never -> :ok
      end
    end

    def cancel(session_id) do
      agent = Application.fetch_env!(:synapsis_agent, :daemon_cleanup_call_agent)
      attempt = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        send(
          Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
          {:owner_death_cleanup, self(), session_id}
        )

        receive do
          :never -> :ok
        end
      else
        :ok
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
      Application.delete_env(:synapsis_agent, :daemon_hanging_event)
      Application.delete_env(:synapsis_agent, :daemon_fake_session_mode)
      Application.delete_env(:synapsis_agent, :daemon_selective_put_if)
      Application.delete_env(:synapsis_agent, :daemon_reconcile_fault_agent)
      Application.delete_env(:synapsis_agent, :daemon_recovery_fault_agent)
      Application.delete_env(:synapsis_agent, :daemon_refill_scan_agent)
      Application.delete_env(:synapsis_agent, :daemon_cleanup_call_agent)
      Application.delete_env(:synapsis_agent, :daemon_deadline_agent)
      Application.delete_env(:synapsis_agent, :daemon_status_agent)
    end)

    :ok
  end

  def wait_for_ready do
    wait_for(fn ->
      case Daemon.status() do
        %{ready: true} = status -> {:ok, status}
        _other -> :retry
      end
    end)
  end

  def wait_for_daemon_pair(old_daemon, old_task_supervisor) do
    wait_for(fn ->
      daemon = Process.whereis(Daemon)
      task_supervisor = Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor)

      if is_pid(daemon) and daemon != old_daemon and is_pid(task_supervisor) and
           task_supervisor != old_task_supervisor do
        {:ok, {daemon, task_supervisor}}
      else
        :retry
      end
    end)
  end

  def start_test_daemon(opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    daemon = String.to_atom("daemon_test_#{suffix}")
    task_supervisor = String.to_atom("daemon_task_supervisor_test_#{suffix}")
    status_publisher = status_publisher_name(daemon)

    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {StatusPublisher,
       [
         name: status_publisher,
         task_supervisor: task_supervisor,
         run_events: Keyword.get(opts, :run_events, Synapsis.Agent.RunEvents),
         event_timeout: Keyword.get(opts, :event_timeout, 1_000),
         retry_ms: Keyword.get(opts, :status_retry_ms, 50)
       ]}
    )

    start_supervised!(
      {Daemon,
       [
         name: daemon,
         task_supervisor: task_supervisor,
         status_publisher: status_publisher,
         recover?: Keyword.get(opts, :recover?, false),
         queue_capacity: Keyword.get(opts, :queue_capacity, 10),
         run_timeout: Keyword.get(opts, :run_timeout, :timer.minutes(30)),
         cleanup_timeout: Keyword.get(opts, :cleanup_timeout, 1_000),
         event_timeout: Keyword.get(opts, :event_timeout, 1_000),
         operation_timeout: Keyword.get(opts, :operation_timeout, 5_000),
         runs: Keyword.get(opts, :runs, Runs),
         run_events: Keyword.get(opts, :run_events, Synapsis.Agent.RunEvents),
         sessions: Keyword.get(opts, :sessions, Synapsis.Sessions)
       ]}
    )

    {daemon, task_supervisor}
  end

  def register_text_provider(tmp_dir, response_text) do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      send_sse(conn, [text_chunk(response_text), finish_chunk("stop")])
    end)

    register_provider_agent(tmp_dir, bypass)
  end

  def controlled_provider(tmp_dir) do
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

  def register_provider_agent(tmp_dir, bypass) do
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

  def daemon_opts(agent_name, provider_name) do
    %{
      assistant_name: agent_name,
      provider: provider_name,
      model: "daemon-test-model"
    }
  end

  def wait_for_run(run_id, status) do
    wait_for(fn ->
      case Runs.get(run_id) do
        %{status: ^status} = run -> {:ok, run}
        _other -> :retry
      end
    end)
  end

  def wait_for_status(daemon, predicate) do
    wait_for(fn ->
      status = Daemon.status(daemon)
      if predicate.(status), do: {:ok, status}, else: :retry
    end)
  end

  def wait_for_task_exit(pid) do
    wait_for(fn -> if Process.alive?(pid), do: :retry, else: {:ok, :gone} end, 500)
  end

  def wait_for_task_children(task_supervisor, expected) do
    wait_for(fn ->
      children = Task.Supervisor.children(task_supervisor)
      if children == expected, do: {:ok, children}, else: :retry
    end)
  end

  def status_publisher_name(daemon), do: String.to_atom("#{daemon}_status_publisher")

  def restore_application_env(key, :missing), do: Application.delete_env(:synapsis_agent, key)
  def restore_application_env(key, value), do: Application.put_env(:synapsis_agent, key, value)

  def text_chunk(text) do
    %{
      "id" => "daemon-response",
      "choices" => [
        %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}
      ]
    }
  end

  def finish_chunk(reason) do
    %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]}
  end

  def send_sse(conn, chunks) do
    body =
      Enum.map_join(chunks, "\n\n", fn chunk -> "data: #{Jason.encode!(chunk)}" end) <>
        "\n\ndata: [DONE]\n\n"

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end

  def wait_for(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  def do_wait_for(fun, deadline) do
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
