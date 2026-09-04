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
               parts: [%Synapsis.Part.Text{content: "Summary inside the bounded slice"}]
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
                     "Outside slice " <>
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
    assert body =~ "Summary inside the bounded slice"
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

  test "generic routine no-overlap and max runtime use the daemon protocol" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(sessions: FakeSessions, run_timeout: 2_000, cleanup_timeout: 50)

    routine_id = Ecto.UUID.generate()
    opts = %{routine_id: routine_id, prompt: "bounded schedule", max_runtime_ms: 50}

    assert {:ok, run} = Daemon.trigger(daemon, :schedule, opts)
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:error, :overlap} = Daemon.trigger(daemon, :schedule, opts)
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
end
