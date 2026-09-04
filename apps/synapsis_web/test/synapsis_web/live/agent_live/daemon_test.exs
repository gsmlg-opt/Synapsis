defmodule SynapsisWeb.AgentLive.DaemonTest do
  use SynapsisWeb.ConnCase, async: false

  alias SynapsisWeb.AgentLive.Daemon

  defmodule DaemonStub do
    def status, do: state().daemon_status

    def submit(prompt, opts) do
      send(state().test_pid, {:manual_submitted, prompt, opts})
      await_result(state().submit_result)
    end

    def cancel(run_id) do
      send(state().test_pid, {:run_cancelled, run_id})
      state().cancel_result
    end

    defp await_result({:await, key, result}) do
      send(state().test_pid, {:operation_waiting, key, self()})

      receive do
        {:release_operation, ^key} -> result
      end
    end

    defp await_result(result), do: result

    defp state, do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state)
  end

  defmodule RunsStub do
    def list_recent(_opts),
      do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state).runs
  end

  defmodule RoutinesStub do
    def list(nil), do: state().routines

    def create(attrs) do
      send(state().test_pid, {:routine_created, attrs})
      state().routine_create_result
    end

    def update(id, attrs) do
      send(state().test_pid, {:routine_updated, id, attrs})
      state().routine_update_result
    end

    def trigger(id) do
      send(state().test_pid, {:routine_triggered, id})
      state().routine_trigger_result
    end

    defp state, do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state)
  end

  defmodule BackplaneStub do
    def list, do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state).connections

    def create(attrs) do
      send(state().test_pid, {:connection_created, attrs})
      await_result(state().connection_create_result)
    end

    def test(id) do
      send(state().test_pid, {:connection_tested, id})
      state().connection_test_result
    end

    def refresh(id) do
      send(state().test_pid, {:connection_refreshed, id})
      state().connection_refresh_result
    end

    def update(id, attrs) do
      send(state().test_pid, {:connection_updated, id, attrs})
      state().connection_update_result
    end

    defp await_result({:await, key, result}) do
      send(state().test_pid, {:operation_waiting, key, self()})

      receive do
        {:release_operation, ^key} -> result
      end
    end

    defp await_result(result), do: result

    defp state, do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state)
  end

  defmodule ProvidersStub do
    def list, do: {:ok, state().providers}
    def cached_models(provider), do: Map.get(provider, :cached_models, [])
    def enabled_models(provider), do: Map.get(provider, :enabled_models, [])

    defp state, do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state)
  end

  defmodule SkillsStub do
    def list, do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state).skills
  end

  defmodule MCPConfigsStub do
    def list, do: Application.fetch_env!(:synapsis_web, :daemon_live_test_state).mcp_configs
  end

  setup do
    previous_deps = Application.get_env(:synapsis_web, Daemon, :missing)
    previous_state = Application.get_env(:synapsis_web, :daemon_live_test_state, :missing)
    now = DateTime.utc_now()

    Application.put_env(:synapsis_web, Daemon,
      daemon: DaemonStub,
      runs: RunsStub,
      routines: RoutinesStub,
      backplane: BackplaneStub,
      providers: ProvidersStub,
      skills: SkillsStub,
      mcp_configs: MCPConfigsStub
    )

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      test_pid: self(),
      daemon_status: %{
        ready: true,
        active_run: %{
          id: "run-active",
          kind: "manual",
          status: "running",
          phase: :running,
          started_at: now
        },
        queued_count: 2,
        last_seen_at: now,
        last_error: nil
      },
      runs: [
        %{
          id: "run-failed",
          kind: "dream",
          status: "failed",
          prompt: "Review memory and open work",
          summary: nil,
          error: "worker timeout",
          inserted_at: now,
          started_at: now,
          finished_at: now
        },
        %{
          id: "run-heartbeat",
          kind: "heartbeat",
          status: "completed",
          prompt: "Check queues",
          summary: "No issues",
          error: nil,
          inserted_at: now,
          started_at: now,
          finished_at: now
        }
      ],
      routines: [
        %{
          "id" => "routine-nightly",
          "name" => "Nightly audit",
          "kind" => "schedule",
          "enabled" => true,
          "schedule" => "0 2 * * *",
          "tool_profile" => "assistant_coding",
          "last_run_at" => "2026-09-05T01:02:03Z",
          "next_run_at" => "2026-09-05T02:02:03Z",
          "last_status" => "completed"
        },
        %{
          "id" => "routine-paused",
          "name" => "Paused dream",
          "kind" => "dream",
          "enabled" => false,
          "schedule" => "0 4 * * *",
          "tool_profile" => "assistant_dream",
          "last_run_at" => nil,
          "next_run_at" => nil,
          "last_status" => nil
        }
      ],
      providers: [
        %{
          id: "provider-one",
          api_key_encrypted: "provider-secret",
          cached_models: [%{id: "model-a"}, %{id: "model-b"}]
        },
        %{id: "provider-two", cached_models: [], enabled_models: ["model-c"]}
      ],
      skills: [%{id: "skill-one"}, %{id: "skill-two"}, %{id: "skill-three"}],
      mcp_configs: [%{id: "mcp-one"}, %{id: "mcp-two"}],
      connections: [
        %{
          id: "connection-live",
          name: "production",
          endpoint: "https://backplane.example",
          enabled: true,
          status: "degraded",
          stale: true,
          last_synced_at: now,
          last_error: "authentication failed for super-secret",
          counts: %{"models" => 3, "skills" => 2, "tools" => 7},
          artifacts: %{
            "provider_id" => "imported-provider",
            "skill_ids" => %{"skill-a" => "imported-skill-a", "skill-b" => "imported-skill-b"},
            "mcp_id" => "imported-mcp"
          },
          credential: "super-secret"
        },
        %{
          id: "connection-paused",
          name: "paused",
          endpoint: "https://paused.example",
          enabled: false,
          status: "disabled",
          stale: false,
          last_synced_at: nil,
          last_error: nil,
          counts: %{},
          artifacts: %{
            "provider_id" => "imported-provider",
            "skill_ids" => %{},
            "mcp_id" => "imported-mcp"
          },
          credential: "another-secret"
        }
      ],
      submit_result: {:ok, %{id: "run-new"}},
      cancel_result: :ok,
      connection_test_result: {:ok, %{status: "ok"}},
      connection_create_result: {:ok, %{id: "connection-new"}},
      connection_refresh_result: {:ok, %{id: "connection-live"}},
      connection_update_result: {:ok, %{id: "connection-live"}},
      routine_create_result: {:ok, %{"id" => "routine-new"}},
      routine_update_result: {:ok, %{"id" => "routine-nightly"}},
      routine_trigger_result: {:ok, %{id: "run-routine"}}
    })

    on_exit(fn ->
      restore_env(Daemon, previous_deps)
      restore_env(:daemon_live_test_state, previous_state)
    end)

    {:ok, now: now}
  end

  test "renders the daemon readiness, active run, and queue summary", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, Daemon)

    assert html =~ "Agent Daemon"
    assert has_element?(view, "#daemon-process-state", "Running")
    assert has_element?(view, "#daemon-readiness", "Ready")
    assert has_element?(view, "#active-run", "run-active")
    assert has_element?(view, "#daemon-queue-count", "2")
    assert has_element?(view, "aside", "Daemon")
    assert has_element?(view, "#agent-mobile-nav", "Daemon")
    assert has_element?(view, "#agent-mobile-nav a[href='/agent/daemon']")
  end

  test "renders imported Backplane capability counts without local-only records", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, Daemon)

    assert has_element?(view, "#daemon-provider-count", "1")
    assert has_element?(view, "#daemon-model-count", "3")
    assert has_element?(view, "#daemon-skill-count", "2")
    assert has_element?(view, "#daemon-mcp-count", "1")
    refute html =~ "provider-secret"
  end

  test "renders recent heartbeat, dream failure, and durable run details", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    assert has_element?(view, "#last-heartbeat", "Check queues")
    assert has_element?(view, "#last-dream", "Review memory and open work")
    assert has_element?(view, "#recent-failures", "worker timeout")
    assert has_element?(view, "#daemon-runs", "run-heartbeat")
    assert has_element?(view, "#daemon-runs", "completed")
    assert has_element?(view, "#daemon-runs", "No issues")
    assert has_element?(view, "#daemon-runs", "run-failed")
  end

  test "redacts secret-bearing durable run errors", %{conn: conn, now: now} do
    state = Application.fetch_env!(:synapsis_web, :daemon_live_test_state)

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      state
      | runs: [
          %{
            id: "run-secret-error",
            kind: "dream",
            status: "failed",
            prompt: "Inspect failure",
            summary: nil,
            error:
              "request failed api_key=run-secret-key Authorization: Bearer bearer-secret password=password-secret",
            inserted_at: now,
            started_at: now,
            finished_at: now
          }
        ]
    })

    {:ok, view, html} = live_isolated(conn, Daemon)
    socket_state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

    assert html =~ "[REDACTED]"
    refute html =~ "run-secret-key"
    refute html =~ "bearer-secret"
    refute html =~ "password-secret"
    refute socket_state =~ "run-secret-key"
    refute socket_state =~ "bearer-secret"
    refute socket_state =~ "password-secret"
  end

  test "queues a bounded manual prompt through the daemon", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    view
    |> form("#manual-run-form", %{"manual" => %{"prompt" => "Inspect the deployment"}})
    |> render_submit()

    assert_receive {:manual_submitted, "Inspect the deployment", %{source: "web"}}
    html = render_async(view, 1_000)
    assert html =~ "Run queued"
    assert has_element?(view, "#manual-run-form textarea[name='manual[prompt]']", "")
  end

  test "runs manual submission asynchronously with visible loading state", %{conn: conn} do
    state = Application.fetch_env!(:synapsis_web, :daemon_live_test_state)

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      state
      | submit_result: {:await, :manual_submit, {:ok, %{id: "run-new"}}}
    })

    {:ok, view, _html} = live_isolated(conn, Daemon)

    submit_task =
      Task.async(fn ->
        view
        |> form("#manual-run-form", %{"manual" => %{"prompt" => "Inspect asynchronously"}})
        |> render_submit()
      end)

    assert_receive {:manual_submitted, "Inspect asynchronously", %{source: "web"}}
    assert_receive {:operation_waiting, :manual_submit, operation_pid}

    event_reply = Task.yield(submit_task, 100)

    if is_nil(event_reply) do
      send(operation_pid, {:release_operation, :manual_submit})
      Task.await(submit_task, 1_000)
    end

    assert {:ok, loading_html} = event_reply
    assert loading_html =~ "Queueing run"
    assert loading_html =~ ~s(aria-busy="true")

    send(operation_pid, {:release_operation, :manual_submit})

    assert render_async(view, 1_000) =~ "Run queued"
  end

  test "cancels the active run", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    view
    |> element("#active-run [phx-click='cancel_run'][phx-value-id='run-active']", "Cancel")
    |> render_click()

    assert_receive {:run_cancelled, "run-active"}
    html = render_async(view, 1_000)
    assert html =~ "Cancellation requested"
  end

  test "refreshes state for mapped daemon PubSub envelopes", %{conn: conn, now: now} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    state = Application.fetch_env!(:synapsis_web, :daemon_live_test_state)

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      state
      | daemon_status: %{state.daemon_status | queued_count: 7},
        runs: [
          %{
            id: "run-pubsub",
            kind: "heartbeat",
            status: "completed",
            prompt: "Refreshed from durable state",
            summary: "Fresh",
            error: nil,
            inserted_at: now,
            started_at: now,
            finished_at: now
          }
        ]
    })

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "agent:daemon",
      {:agent_daemon_event, %{event: "agent.run.completed", run_id: "run-pubsub"}}
    )

    assert render(view) =~ "run-pubsub"
    assert has_element?(view, "#daemon-queue-count", "7")
    assert has_element?(view, "#last-heartbeat", "Refreshed from durable state")
  end

  test "refreshes routines for the durable routine update envelope", %{conn: conn, now: now} do
    {:ok, view, _html} = live_isolated(conn, Daemon)
    state = Application.fetch_env!(:synapsis_web, :daemon_live_test_state)

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      state
      | routines: [
          %{
            "id" => "routine-pubsub",
            "name" => "Updated after persistence",
            "kind" => "schedule",
            "enabled" => true,
            "schedule" => "*/10 * * * *",
            "last_status" => "completed"
          }
        ]
    })

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "agent:daemon",
      {:agent_daemon_event,
       %{
         event: "agent.routine.updated",
         routine_id: "routine-pubsub",
         kind: "schedule",
         at: now
       }}
    )

    assert render(view) =~ "Updated after persistence"
    assert has_element?(view, "#routine-routine-pubsub", "completed")
  end

  test "renders Backplane state and imported counts without credentials", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, Daemon)

    assert has_element?(view, "#backplane-connections", "production")
    assert has_element?(view, "#connection-connection-live", "https://backplane.example")
    assert has_element?(view, "#connection-connection-live", "degraded")
    assert has_element?(view, "#connection-connection-live", "Stale")
    assert has_element?(view, "#connection-connection-live", "3 models")
    assert has_element?(view, "#connection-connection-live", "2 skills")
    assert has_element?(view, "#connection-connection-live", "7 tools")
    assert html =~ "authentication failed for [REDACTED]"
    refute html =~ "super-secret"
    refute html =~ "another-secret"
  end

  test "does not retain decrypted Backplane credentials in socket assigns", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    socket_state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

    refute socket_state =~ "super-secret"
    refute socket_state =~ "another-secret"
    refute socket_state =~ "provider-secret"
  end

  test "creates a Backplane capability source asynchronously without retaining its credential", %{
    conn: conn
  } do
    state = Application.fetch_env!(:synapsis_web, :daemon_live_test_state)

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      state
      | connection_create_result: {:await, :connection_create, {:ok, %{id: "connection-new"}}}
    })

    {:ok, view, _html} = live_isolated(conn, Daemon)

    create_task =
      Task.async(fn ->
        view
        |> form("#backplane-create-form", %{
          "connection" => %{
            "name" => "new-source",
            "endpoint" => "https://new-backplane.example",
            "credential" => "create-secret",
            "enabled" => "true",
            "sync_on_start" => "true",
            "trust_mcp_annotations" => "true"
          }
        })
        |> render_submit()
      end)

    assert_receive {:connection_created,
                    %{
                      name: "new-source",
                      endpoint: "https://new-backplane.example",
                      credential: "create-secret",
                      enabled: true,
                      sync_on_start: true,
                      connection_options: %{"trust_mcp_annotations" => true}
                    }}

    assert_receive {:operation_waiting, :connection_create, operation_pid}
    event_reply = Task.yield(create_task, 100)

    if is_nil(event_reply) do
      send(operation_pid, {:release_operation, :connection_create})
      Task.await(create_task, 1_000)
    end

    assert {:ok, loading_html} = event_reply
    assert loading_html =~ "Creating connection"
    assert loading_html =~ ~s(aria-busy="true")

    send(operation_pid, {:release_operation, :connection_create})
    assert render_async(view, 1_000) =~ "Connection created"

    socket_state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
    refute socket_state =~ "create-secret"
  end

  test "validates Backplane source creation and reports sanitized failures", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    html =
      view
      |> form("#backplane-create-form", %{
        "connection" => %{"name" => "", "endpoint" => ""}
      })
      |> render_submit()

    assert html =~ "Name and endpoint are required"
    refute_receive {:connection_created, _attrs}

    state = Application.fetch_env!(:synapsis_web, :daemon_live_test_state)

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      state
      | connection_create_result: {:error, "credential failing-secret rejected"}
    })

    view
    |> form("#backplane-create-form", %{
      "connection" => %{
        "name" => "failing-source",
        "endpoint" => "https://failing.example",
        "credential" => "failing-secret",
        "enabled" => "true",
        "sync_on_start" => "true"
      }
    })
    |> render_submit()

    assert_receive {:connection_created, %{credential: "failing-secret"}}
    html = render_async(view, 1_000)
    assert html =~ "Unable to create the connection"
    refute html =~ "failing-secret"

    socket_state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
    refute socket_state =~ "failing-secret"
  end

  test "tests, refreshes, disables, and enables Backplane connections", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    view
    |> element("#connection-connection-live [phx-click='test_connection']", "Test")
    |> render_click()

    assert_receive {:connection_tested, "connection-live"}
    render_async(view, 1_000)

    view
    |> element("#connection-connection-live [phx-click='refresh_connection']", "Refresh")
    |> render_click()

    assert_receive {:connection_refreshed, "connection-live"}
    render_async(view, 1_000)

    view
    |> element("#connection-connection-live [phx-click='set_connection_enabled']", "Disable")
    |> render_click()

    assert_receive {:connection_updated, "connection-live", %{enabled: false}}
    render_async(view, 1_000)

    view
    |> element("#connection-connection-paused [phx-click='set_connection_enabled']", "Enable")
    |> render_click()

    assert_receive {:connection_updated, "connection-paused", %{enabled: true}}
    render_async(view, 1_000)
  end

  test "renders routines with schedule, toolset, and execution times", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    assert has_element?(view, "#daemon-routines", "Nightly audit")
    assert has_element?(view, "#routine-routine-nightly", "0 2 * * *")
    assert has_element?(view, "#routine-routine-nightly", "assistant_coding")
    assert has_element?(view, "#routine-routine-nightly", "Last")
    assert has_element?(view, "#routine-routine-nightly", "Next")
    assert has_element?(view, "#routine-routine-nightly", "2026-09-05 01:02:03 UTC")
    assert has_element?(view, "#routine-routine-nightly", "2026-09-05 02:02:03 UTC")
    assert has_element?(view, "#routine-routine-paused", "Disabled")
  end

  test "creates a minimum scheduled routine", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    view
    |> form("#routine-create-form", %{
      "routine" => %{
        "name" => "Deploy watch",
        "kind" => "schedule",
        "schedule" => "*/15 * * * *",
        "tool_profile" => "assistant_basic",
        "prompt" => "Inspect deploy health",
        "enabled" => "true"
      }
    })
    |> render_submit()

    assert_receive {:routine_created,
                    %{
                      "name" => "Deploy watch",
                      "kind" => "schedule",
                      "schedule" => "*/15 * * * *",
                      "tool_profile" => "assistant_basic",
                      "prompt" => "Inspect deploy health",
                      "enabled" => true
                    }}

    html = render_async(view, 1_000)
    assert html =~ "Routine created"
  end

  test "enables, disables, and runs routines now", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, Daemon)

    view
    |> element("#routine-routine-nightly [phx-click='set_routine_enabled']", "Disable")
    |> render_click()

    assert_receive {:routine_updated, "routine-nightly", %{"enabled" => false}}
    render_async(view, 1_000)

    view
    |> element("#routine-routine-paused [phx-click='set_routine_enabled']", "Enable")
    |> render_click()

    assert_receive {:routine_updated, "routine-paused", %{"enabled" => true}}
    render_async(view, 1_000)

    view
    |> element("#routine-routine-nightly [phx-click='trigger_routine']", "Run now")
    |> render_click()

    assert_receive {:routine_triggered, "routine-nightly"}
    render_async(view, 1_000)
  end

  test "shows bounded action failures without leaking credentials", %{conn: conn} do
    state = Application.fetch_env!(:synapsis_web, :daemon_live_test_state)

    Application.put_env(:synapsis_web, :daemon_live_test_state, %{
      state
      | connection_test_result: {:error, "token super-secret refused"}
    })

    {:ok, view, _html} = live_isolated(conn, Daemon)

    view
    |> element("#connection-connection-live [phx-click='test_connection']", "Test")
    |> render_click()

    html = render_async(view, 1_000)
    assert html =~ "Backplane operation failed"
    refute html =~ "super-secret"
  end

  defp restore_env(key, :missing), do: Application.delete_env(:synapsis_web, key)
  defp restore_env(key, value), do: Application.put_env(:synapsis_web, key, value)
end
