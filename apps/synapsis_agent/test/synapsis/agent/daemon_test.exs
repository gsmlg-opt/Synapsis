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

  setup do
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
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
    assert %{ready: true, active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
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
                 %{ready: true, recovery_error: error} = status when is_binary(error) ->
                   {:ok, status}

                 _other ->
                   :retry
               end
             end)

    assert status.recovery_error =~ "store_unavailable"
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
         queue_capacity: Keyword.get(opts, :queue_capacity, 10)
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
