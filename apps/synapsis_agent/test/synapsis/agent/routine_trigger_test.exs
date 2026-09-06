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

    def store(attrs) do
      record = Map.put(attrs, :id, "dream-saved-#{System.unique_integer([:positive])}")

      Agent.update(
        Application.fetch_env!(:synapsis_agent, :dream_test_memory_store),
        &[record | &1]
      )

      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:dream_memory_stored, record}
      )

      {:ok, record}
    end

    def list(_filters) do
      Agent.get(
        Application.fetch_env!(:synapsis_agent, :dream_test_memory_store),
        &Enum.reverse/1
      )
    end
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
      Jason.encode!(%{
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
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:schedule_provider_request, request_number, request, self()})

      case request_number do
        1 ->
          receive do
            :respond ->
              send_sse(conn, [
                tool_call_chunk("file_read", "schedule-file-read", %{"path" => "scheduled.txt"}),
                finish_chunk("tool_calls")
              ])
          after
            5_000 -> Plug.Conn.send_resp(conn, 500, "test did not release schedule tool response")
          end

        2 ->
          send_sse(conn, [text_chunk("scheduled work completed"), finish_chunk("stop")])
      end
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
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

    tool_names = Enum.map(first_request["tools"], &get_in(&1, ["function", "name"]))
    assert "file_read" in tool_names
    refute "file_write" in tool_names
    refute "bash" in tool_names

    assert {:ok, running} = wait_for_run(schedule.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")
    send(request_pid, :respond)

    assert_receive {:schedule_provider_request, 2, second_request, _request_pid}, 2_000

    assert %{
             "role" => "tool",
             "tool_call_id" => "schedule-file-read",
             "content" => ^file_content
           } = Enum.find(second_request["messages"], &(&1["role"] == "tool"))

    refute_receive {"permission_requests", _payload}, 100
    assert {:ok, completed} = wait_for_run(schedule.id, "completed")
    assert completed.summary == "scheduled work completed"
  end

  @tag :tmp_dir
  test "dream persists a memory through memory_save without a permission request", %{
    tmp_dir: tmp_dir
  } do
    previous_adapter = Application.get_env(:synapsis_core, :memory_adapter)
    memory_store = start_supervised!({Agent, fn -> [] end})
    Application.put_env(:synapsis_core, :memory_adapter, DreamMemoryAdapter)
    Application.put_env(:synapsis_agent, :dream_test_memory_store, memory_store)

    on_exit(fn ->
      Application.delete_env(:synapsis_agent, :dream_test_memory_store)

      if previous_adapter,
        do: Application.put_env(:synapsis_core, :memory_adapter, previous_adapter),
        else: Application.delete_env(:synapsis_core, :memory_adapter)
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
      Jason.encode!(%{
        "recent_summary" => "Saved the release lesson",
        "memory_candidates" => ["Verify imported tools"],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    owner = self()
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:dream_memory_provider_request, request_number, request, self()})

      case request_number do
        1 ->
          receive do
            :respond ->
              send_sse(conn, [
                tool_call_chunk("memory_save", "dream-memory-call", memory_input),
                finish_chunk("tool_calls")
              ])
          after
            5_000 -> Plug.Conn.send_resp(conn, 500, "test did not release memory tool response")
          end

        2 ->
          send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
      end
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:ok, dream} =
             Daemon.trigger(daemon, :dream, %{
               routine_id: Ecto.UUID.generate(),
               prompt: "reflect and retain the release lesson",
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert_receive {:dream_memory_provider_request, 1, first_request, request_pid}, 2_000

    assert "memory_save" in Enum.map(first_request["tools"], &get_in(&1, ["function", "name"]))
    refute "bash" in Enum.map(first_request["tools"], &get_in(&1, ["function", "name"]))

    assert {:ok, running} = wait_for_run(dream.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")
    send(request_pid, :respond)

    assert_receive {:dream_memory_stored,
                    %{
                      scope: "agent",
                      scope_id: ^agent_name,
                      kind: "lesson",
                      title: "Verify imported tools",
                      contributed_by: ^agent_name
                    } = saved},
                   2_000

    assert_receive {:dream_memory_provider_request, 2, second_request, _request_pid}, 2_000
    assert Jason.encode!(second_request) =~ "Verify imported tools"
    assert Jason.encode!(second_request) =~ "saved"
    refute_receive {"permission_requests", _payload}, 100

    assert [persisted] = Synapsis.Memory.list_semantic(scope: "agent", scope_id: agent_name)
    assert persisted.id == saved.id
    assert {:ok, completed} = wait_for_run(dream.id, "completed")
    assert completed.metadata["output"]["recent_summary"] == "Saved the release lesson"
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
    bypass = Bypass.open()

    dream_json =
      Jason.encode!(%{
        "recent_summary" => "Reviewed bounded context",
        "memory_candidates" => [],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:dream_request, body})
      send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)

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
    bypass = Bypass.open()

    dream_json =
      Jason.encode!(%{
        "recent_summary" => "Reviewed project status",
        "memory_candidates" => [],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:dream_project_status_request, body})
      send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
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
    bypass = Bypass.open()

    dream_json =
      Jason.encode!(%{
        "recent_summary" => "Reviewed bounded context",
        "memory_candidates" => [],
        "open_questions" => [],
        "risks" => [],
        "proposed_tasks" => [],
        "ignored_noise" => []
      })

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:bounded_dream_request, body})
      send_sse(conn, [text_chunk(dream_json), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)

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
      Jason.encode!(%{
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
      Jason.encode!(%{
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
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      Plug.Conn.send_resp(conn, 503, "provider unavailable")
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
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

  defp tool_call_chunk(tool_name, tool_call_id, input) do
    %{
      "id" => "dream-tool-response",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => tool_call_id,
                "type" => "function",
                "function" => %{"name" => tool_name, "arguments" => Jason.encode!(input)}
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }
  end
end
