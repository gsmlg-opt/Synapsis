defmodule Synapsis.Agent.RoutineTriggerTest do
  use Synapsis.Agent.DaemonCase, async: false

  defmodule DreamMemoryAdapter do
    def search(query, filters) do
      send(Application.fetch_env!(:synapsis_agent, :daemon_test_owner), {
        :dream_memory_search,
        query,
        filters
      })

      memories =
        Application.get_env(:synapsis_agent, :dream_test_memories, [
          %{
            id: "dream-memory",
            scope: "shared",
            scope_id: "",
            kind: "lesson",
            title: "Deployment lesson",
            summary: "Verify the live endpoint after restart",
            tags: [],
            contributed_by: "test",
            importance: 0.8,
            confidence: 0.9,
            freshness: 1.0,
            inserted_at: DateTime.utc_now()
          }
        ])

      if is_function(memories, 1), do: memories.(query), else: memories
    end

    def touch_accessed(_ids), do: :ok
  end

  @tag :tmp_dir
  test "manual schedule and dream triggers persist structured terminal output", %{
    tmp_dir: tmp_dir
  } do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = register_text_provider(tmp_dir, "scheduled result")

    assert {:ok, schedule} =
             Daemon.trigger(daemon, :schedule, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "run scheduled work",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert schedule.kind == "schedule"
    assert schedule.tool_profile == "assistant_basic"
    assert {:ok, completed} = wait_for_run(schedule.id, "completed")
    assert completed.summary == "scheduled result"

    assert completed.metadata["output"] == %{
             "kind" => "schedule",
             "status" => "completed",
             "summary" => "scheduled result"
           }

    dream_json =
      Formata.JSON.encode!(%{
        "recent_summary" => "Reviewed recent work",
        "memory_candidates" => ["Keep the deployment lesson"],
        "open_questions" => ["Is the retry budget sufficient?"],
        "risks" => ["Silent scheduler failure"],
        "proposed_tasks" => ["Add a bounded trigger task"],
        "ignored_noise" => ["Unrelated UI work"]
      })

    {provider_name, agent_name} = register_text_provider(tmp_dir, dream_json)

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert dream.kind == "dream"
    assert dream.tool_profile == "assistant_dream"
    assert {:ok, completed_dream} = wait_for_run(dream.id, "completed")

    assert completed_dream.metadata["output"] == %{
             "recent_summary" => "Reviewed recent work",
             "memory_candidates" => ["Keep the deployment lesson"],
             "open_questions" => ["Is the retry budget sufficient?"],
             "risks" => ["Silent scheduler failure"],
             "proposed_tasks" => ["Add a bounded trigger task"],
             "ignored_noise" => ["Unrelated UI work"]
           }
  end

  @tag :tmp_dir
  test "schedule executes a safe tool through the daemon without a permission request", %{
    tmp_dir: tmp_dir
  } do
    file_content = "scheduled safe tool result"
    File.write!(Path.join(tmp_dir, "scheduled.txt"), file_content)

    owner = self()
    fixture = Gaoxy.Test.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Gaoxy.Test.expect(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:schedule_provider_request, request_number, request, self()})

      case request_number do
        1 ->
          receive do
            :respond ->
              send_sse(conn, [
                tool_call_chunk(
                  Synapsis.Provider.ToolName.encode("synapsis::read"),
                  "schedule-file-read",
                  %{"path" => "scheduled.txt"}
                ),
                finish_chunk("tool_calls")
              ])
          after
            5_000 -> Plug.Conn.send_resp(conn, 500, "test did not release schedule tool response")
          end

        2 ->
          send_sse(conn, [text_chunk("scheduled work completed"), finish_chunk("stop")])
      end
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, fixture)
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, schedule} =
             Daemon.trigger(daemon, :schedule, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "read the scheduled input",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert_receive {:schedule_provider_request, 1, first_request, request_pid}, 2_000

    tool_names = Enum.map(first_request["tools"], & &1["name"])
    assert Synapsis.Provider.ToolName.encode("synapsis::read") in tool_names
    refute Synapsis.Provider.ToolName.encode("synapsis::write") in tool_names
    refute "exec_command" in tool_names

    assert {:ok, running} = wait_for_run(schedule.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")
    send(request_pid, :respond)

    assert_receive {:schedule_provider_request, 2, second_request, _request_pid}, 2_000

    assert %{
             "type" => "function_call_output",
             "call_id" => "schedule-file-read",
             "output" => ^file_content
           } = Enum.find(second_request["input"], &(&1["type"] == "function_call_output"))

    refute_receive {"permission_requests", _payload}, 100
    assert {:ok, completed} = wait_for_run(schedule.id, "completed")
    assert completed.summary == "scheduled work completed"
  end

  @tag :tmp_dir
  test "dream persists a memory through memory_save without a permission request", %{
    tmp_dir: tmp_dir
  } do
    previous_adapter = Application.get_env(:synapsis_core, :memory_adapter)
    previous_dir = System.get_env("SYNAPSIS_MEMORY_DIR")
    records = Path.join(tmp_dir, "memories")
    File.mkdir_p!(records)
    System.put_env("SYNAPSIS_MEMORY_DIR", records)
    Application.put_env(:synapsis_core, :memory_adapter, Synapsis.Memory.FileAdapter)
    Synapsis.Memory.Cache.clear()

    on_exit(fn ->
      if previous_dir,
        do: System.put_env("SYNAPSIS_MEMORY_DIR", previous_dir),
        else: System.delete_env("SYNAPSIS_MEMORY_DIR")

      if previous_adapter,
        do: Application.put_env(:synapsis_core, :memory_adapter, previous_adapter),
        else: Application.delete_env(:synapsis_core, :memory_adapter)

      Synapsis.Memory.Cache.clear()
    end)

    memory_input = %{
      "memories" => [
        %{
          "scope" => "agent",
          "kind" => "lesson",
          "title" => "Verify imported tools",
          "summary" => "Exercise imported tools through the daemon before release.",
          "tags" => ["release"]
        }
      ]
    }

    dream_json =
      Formata.JSON.encode!(%{
        "recent_summary" => "Saved the release lesson",
        "memory_candidates" => ["Verify imported tools"],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    owner = self()
    fixture = Gaoxy.Test.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Gaoxy.Test.expect(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:dream_memory_provider_request, request_number, request, self()})

      case request_number do
        1 ->
          receive do
            :respond ->
              send_sse(conn, [
                tool_call_chunk(
                  Synapsis.Provider.ToolName.encode("synapsis::memory_save"),
                  "dream-memory-call",
                  memory_input
                ),
                finish_chunk("tool_calls")
              ])
          after
            5_000 -> Plug.Conn.send_resp(conn, 500, "test did not release memory tool response")
          end

        2 ->
          send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
      end
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, fixture)
    %{id: agent_id} = Synapsis.AgentConfigs.get_by_name(agent_name)
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect and retain the release lesson",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert dream.assistant_name == agent_name
    assert dream.capability_snapshot["agent_id"] == agent_id
    assert_receive {:dream_memory_provider_request, 1, first_request, request_pid}, 2_000

    assert Synapsis.Provider.ToolName.encode("synapsis::memory_save") in Enum.map(
             first_request["tools"],
             & &1["name"]
           )

    refute "exec_command" in Enum.map(first_request["tools"], & &1["name"])

    assert {:ok, running} = wait_for_run(dream.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")

    assert %{root: %{status: :running, run_id: native_run_id}} =
             Synapsis.Session.Worker.snapshot(running.session_id).subagents

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "memory:agent:#{agent_id}")
    send(request_pid, :respond)

    assert_receive {:memory_promoted, memory_id}, 2_000

    assert {:ok,
            %{
              scope: "agent",
              scope_id: ^agent_id,
              kind: "lesson",
              title: "Verify imported tools",
              contributed_by: ^agent_id
            } = saved} = Synapsis.Memory.get_semantic(memory_id)

    assert File.exists?(Path.join([records, "agent", agent_id, "#{memory_id}.md"]))

    assert_receive {:dream_memory_provider_request, 2, second_request, _request_pid}, 2_000

    assert %{
             "type" => "function_call_output",
             "call_id" => "dream-memory-call",
             "output" => output
           } = Enum.find(second_request["input"], &(&1["type"] == "function_call_output"))

    assert output == "Saved #{memory_id}: Verify imported tools"
    refute_receive {"permission_requests", _payload}, 100
    refute_receive {"runtime_permissions", [_pending | _]}, 100

    assert [persisted] = Synapsis.Memory.list_semantic(scope: "agent", scope_id: agent_id)
    assert persisted.id == saved.id
    assert {:ok, completed} = wait_for_run(dream.id, "completed")
    assert completed.metadata["output"]["recent_summary"] == "Saved the release lesson"

    assert %{root: %{status: :completed, run_id: ^native_run_id}} =
             Synapsis.Session.Worker.snapshot(completed.session_id).subagents

    assert {:ok, %{active_run_id: nil, queued_count: 0}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  @tag :tmp_dir
  test "dream prompt includes failed heartbeat runs, session summaries, memory, todos, and workspace status",
       %{
         tmp_dir: tmp_dir
       } do
    previous_adapter = Application.get_env(:synapsis_core, :memory_adapter)
    Application.put_env(:synapsis_core, :memory_adapter, DreamMemoryAdapter)

    on_exit(fn ->
      if previous_adapter,
        do: Application.put_env(:synapsis_core, :memory_adapter, previous_adapter),
        else: Application.delete_env(:synapsis_core, :memory_adapter)
    end)

    assert {:ok, _recent} =
             Runs.create(%{
               kind: "heartbeat",
               status: "failed",
               source: "system",
               heartbeat_id: Ecto.UUID.generate(),
               routine_id: Ecto.UUID.generate(),
               prompt: "prior heartbeat",
               tool_profile: "assistant_basic",
               error: "prior heartbeat failed"
             })

    owner = self()
    fixture = Gaoxy.Test.open()

    dream_json =
      Formata.JSON.encode!(%{
        "recent_summary" => "Reviewed bounded context",
        "memory_candidates" => [],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:dream_request, body})
      send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, fixture)

    assert {:ok, recent_session} =
             Synapsis.Sessions.create(agent_name, %{
               provider: provider_name,
               model: "daemon-test-model",
               title: "Prior deploy session"
             })

    assert {:ok, _message} =
             Synapsis.Message.append(recent_session.id, %{
               role: "assistant",
               parts: [%Synapsis.Part.Text{content: "Session summary: deployment was verified"}]
             })

    assert :ok =
             Synapsis.Session.Store.put_value(recent_session.id, "todos", [
               %{
                 "todo_id" => Ecto.UUID.generate(),
                 "content" => "Recheck the deploy tomorrow",
                 "status" => "pending",
                 "sort_order" => 0
               }
             ])

    assert {:ok, todo_only_session} =
             Synapsis.Sessions.create(agent_name, %{
               provider: provider_name,
               model: "daemon-test-model",
               title: "Session without a summary"
             })

    assert :ok =
             Synapsis.Session.Store.put_value(todo_only_session.id, "todos", [
               %{
                 "todo_id" => Ecto.UUID.generate(),
                 "content" => "Follow up even without a session summary",
                 "status" => "pending",
                 "sort_order" => 0
               }
             ])

    workspace_path =
      "/agents/#{agent_name}/plans/dream-context-#{System.unique_integer([:positive])}.md"

    assert {:ok, _resource} =
             Synapsis.Workspace.write(workspace_path, "Current rollout plan", %{
               author: agent_name
             })

    on_exit(fn ->
      Synapsis.Sessions.delete(recent_session.id)
      Synapsis.Sessions.delete(todo_only_session.id)
      Synapsis.Workspace.delete(workspace_path)
    end)

    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect on recent activity",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert dream.tool_profile == "assistant_dream"
    assert_receive {:dream_memory_search, "reflect on recent activity", filters}, 2_000
    assert filters[:limit] == 5
    assert_receive {:dream_request, body}, 2_000
    assert body =~ "reflect on recent activity"
    assert body =~ "heartbeat failed: prior heartbeat failed"
    assert body =~ "Prior deploy session"
    assert body =~ "Session summary: deployment was verified"
    assert body =~ "Deployment lesson"
    assert body =~ "Verify the live endpoint after restart"
    assert body =~ "Recheck the deploy tomorrow"
    assert body =~ "Follow up even without a session summary"
    assert body =~ workspace_path
    assert body =~ "recent_summary"
    assert body =~ "ignored_noise"
    assert {:ok, _completed} = wait_for_run(dream.id, "completed")
  end

  @tag :tmp_dir
  test "dream project status is read-only for a dirty git repository", %{tmp_dir: tmp_dir} do
    git!(tmp_dir, ["init", "-q"])
    git!(tmp_dir, ["config", "user.email", "test@synapsis.local"])
    git!(tmp_dir, ["config", "user.name", "Synapsis Test"])
    File.write!(Path.join(tmp_dir, "tracked.txt"), "original\n")
    git!(tmp_dir, ["add", "."])
    git!(tmp_dir, ["commit", "-q", "-m", "init"])
    File.write!(Path.join(tmp_dir, "tracked.txt"), "dirty\n")
    File.write!(Path.join(tmp_dir, "untracked.txt"), "new\n")

    refs_before = git!(tmp_dir, ["show-ref"])
    objects_before = git!(tmp_dir, ["count-objects", "-v"])
    owner = self()
    fixture = Gaoxy.Test.open()

    dream_json =
      Formata.JSON.encode!(%{
        "recent_summary" => "Reviewed project status",
        "memory_candidates" => [],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:dream_project_status_request, body})
      send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, fixture)
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect on project status",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert_receive {:dream_project_status_request, body}, 2_000
    assert body =~ "Project status:"
    assert body =~ "- workspace root: #{tmp_dir}"
    assert body =~ "- working tree: dirty"
    assert git!(tmp_dir, ["show-ref"]) == refs_before
    assert git!(tmp_dir, ["count-objects", "-v"]) == objects_before
    assert {:ok, _completed} = wait_for_run(dream.id, "completed")
  end

  @tag :tmp_dir
  test "dream prompt bounds and sanitizes run, memory, and per-session message context", %{
    tmp_dir: tmp_dir
  } do
    previous_adapter = Application.get_env(:synapsis_core, :memory_adapter)
    Application.put_env(:synapsis_core, :memory_adapter, DreamMemoryAdapter)

    oversized_memory = %{
      id: "oversized-dream-memory",
      scope: "shared",
      scope_id: "",
      kind: "lesson",
      title: "Memory " <> String.duplicate("T", 1_000) <> "MEMORY_TITLE_TAIL",
      summary: "Memory safe\0text " <> String.duplicate("M", 2_000) <> "MEMORY_SUMMARY_TAIL",
      tags: [],
      contributed_by: "test",
      importance: 0.8,
      confidence: 0.9,
      freshness: 1.0,
      inserted_at: DateTime.utc_now()
    }

    Application.put_env(:synapsis_agent, :dream_test_memories, fn
      "reflect on bounded inputs" -> [oversized_memory]
      _other_query -> []
    end)

    on_exit(fn ->
      Application.delete_env(:synapsis_agent, :dream_test_memories)

      if previous_adapter,
        do: Application.put_env(:synapsis_core, :memory_adapter, previous_adapter),
        else: Application.delete_env(:synapsis_core, :memory_adapter)
    end)

    assert {:ok, _recent} =
             Runs.create(%{
               kind: "heartbeat",
               status: "failed",
               source: "system",
               heartbeat_id: Ecto.UUID.generate(),
               routine_id: Ecto.UUID.generate(),
               prompt: "oversized prior heartbeat",
               tool_profile: "assistant_basic",
               error:
                 "Bounded failure " <>
                   String.duplicate("R", 2_000) <> "AGENT_RUN_ERROR_TAIL"
             })

    owner = self()
    fixture = Gaoxy.Test.open()

    dream_json =
      Formata.JSON.encode!(%{
        "recent_summary" => "Reviewed bounded context",
        "memory_candidates" => [],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:bounded_dream_request, body})
      send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, fixture)

    assert {:ok, recent_session} =
             Synapsis.Sessions.create(agent_name, %{
               provider: provider_name,
               model: "daemon-test-model",
               title: "Bounded history session"
             })

    assert {:ok, _message} =
             Synapsis.Message.append(recent_session.id, %{
               role: "assistant",
               parts: [%Synapsis.Part.Text{content: "Oldest summary must be ignored"}]
             })

    for index <- 1..19 do
      assert {:ok, _message} =
               Synapsis.Message.append(recent_session.id, %{
                 role: "user",
                 parts: [%Synapsis.Part.Text{content: "bounded filler #{index}"}]
               })
    end

    assert {:ok, _message} =
             Synapsis.Message.append(recent_session.id, %{
               role: "assistant",
               parts: [
                 %Synapsis.Part.Text{
                   content:
                     "Latest fallback summary " <>
                       String.duplicate("S", 2_000) <> "SESSION_HISTORY_TAIL"
                 }
               ]
             })

    on_exit(fn -> Synapsis.Sessions.delete(recent_session.id) end)

    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect on bounded inputs",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert_receive {:bounded_dream_request, body}, 2_000
    assert body =~ "Bounded failure"
    assert body =~ "Memory safe text"
    assert body =~ "Latest fallback summary"
    refute body =~ "Oldest summary must be ignored"
    refute body =~ "AGENT_RUN_ERROR_TAIL"
    refute body =~ "MEMORY_TITLE_TAIL"
    refute body =~ "MEMORY_SUMMARY_TAIL"
    refute body =~ "SESSION_HISTORY_TAIL"
    refute body =~ "\\u0000"
    assert {:ok, _completed} = wait_for_run(dream.id, "completed")
  end

  @tag :tmp_dir
  test "dream output rejects free-form text instead of coercing it to a successful structure", %{
    tmp_dir: tmp_dir
  } do
    {provider_name, agent_name} = register_text_provider(tmp_dir, "free-form reflection")
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert {:ok, failed} = wait_for_run(dream.id, "failed")
    assert failed.error =~ "invalid_dream_output"
    refute Map.has_key?(failed.metadata, "output")
    assert %{ready: true} = Daemon.status(daemon)
  end

  @tag :tmp_dir
  test "dream output rejects an empty recent summary", %{tmp_dir: tmp_dir} do
    empty =
      Formata.JSON.encode!(%{
        "recent_summary" => "",
        "memory_candidates" => [],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    assert_invalid_dream_output(tmp_dir, empty)
  end

  @tag :tmp_dir
  test "dream output rejects an inexact six-field shape", %{tmp_dir: tmp_dir} do
    inexact =
      Formata.JSON.encode!(%{
        "recent_summary" => "reflection",
        "memory_candidates" => "not-a-list",
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => [],
        "extra" => []
      })

    assert_invalid_dream_output(tmp_dir, inexact)
  end

  @tag :tmp_dir
  test "provider failure leaves the dream run failed and the daemon healthy", %{tmp_dir: tmp_dir} do
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
      Plug.Conn.send_resp(conn, 503, "provider unavailable")
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, fixture)
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert {:ok, failed} = wait_for_run(dream.id, "failed")
    assert is_binary(failed.error)

    assert {:ok, %{ready: true, active_run_id: nil}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "dream no-overlap and max runtime use the daemon protocol" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(sessions: FakeSessions, run_timeout: 2_000, cleanup_timeout: 50)

    routine_id = Ecto.UUID.generate()
    opts = %{routine_id: routine_id, prompt: "bounded dream", max_runtime_ms: 50}

    assert {:ok, run} = Daemon.trigger(daemon, :dream, opts)
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:error, :overlap} = Daemon.trigger(daemon, :dream, opts)
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "session_timeout"
  end

  defp assert_invalid_dream_output(tmp_dir, output) do
    {provider_name, agent_name} = register_text_provider(tmp_dir, output)
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert {:ok, failed} = wait_for_run(dream.id, "failed")
    assert failed.error =~ "invalid_dream_output"
    refute Map.has_key?(failed.metadata, "output")
    assert %{ready: true} = Daemon.status(daemon)
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp tool_call_chunk(tool_name, tool_call_id, input),
    do:
      Synapsis.Provider.TestSupport.ResponsesFixture.function_call(tool_name, tool_call_id, input)
end
