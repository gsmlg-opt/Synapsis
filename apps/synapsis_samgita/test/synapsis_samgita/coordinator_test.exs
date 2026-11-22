defmodule SynapsisSamgita.CoordinatorTest do
  use ExUnit.Case, async: false
  alias Synapsis.Samgita.{Coordination, Devices, Executions, Inbox}
  alias SynapsisSamgita.{Coordinator, Inbound}
  alias SynapsisSamgita.Coordinator.Worker
  alias SynapsisSamgita.Test.SamgitaStub, as: Stub

  @manager "10000000-0000-4000-8000-000000000001"
  @worker "10000000-0000-4000-8000-000000000002"
  @root "20000000-0000-4000-8000-000000000001"
  @one "20000000-0000-4000-8000-000000000002"
  @two "20000000-0000-4000-8000-000000000003"

  defmodule Planner do
    def plan(_, _, candidates, _) do
      Process.put(:plans, Process.get(:plans, 0) + 1)
      {:ok, SynapsisSamgita.CoordinatorTest.plan(hd(candidates))}
    end
  end

  defmodule Host do
    def init(opts), do: opts

    def call(%{request_path: "/app-server"} = conn, opts),
      do: SynapsisSamgita.Test.IngressHost.call(conn, opts)

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      response =
        Req.request!(
          method: conn.method,
          url: opts[:http_url] <> conn.request_path,
          headers: conn.req_headers,
          body: body,
          retry: false,
          receive_timeout: 5_000
        )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(response.status, JSON.encode!(response.body))
    end
  end

  setup do
    for device <- Devices.list(), do: Inbound.disconnect(device["id"])
    Synapsis.DataCase.clear_config_store(:samgita)
    clear!()
    server = Gaoxy.Test.open()

    {:ok, state} =
      Agent.start_link(fn -> %{writes: [], tasks: %{}, events: [], roles: ["manager"]} end)

    owner = self()
    install_execution_callbacks(server, state, owner)

    Gaoxy.Test.stub(server, "GET", "/api/agent/projects/project-1/context", fn conn ->
      roles = Agent.get(state, & &1.roles)
      Stub.json(conn, 200, %{"data" => context(roles)})
    end)

    Gaoxy.Test.stub(server, "GET", "/api/agent/projects/project-1/events", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      after_sequence = String.to_integer(conn.query_params["after"] || "0")
      send(owner, {:event_page, after_sequence})

      events =
        Agent.get(state, & &1.events)
        |> Enum.filter(&((&1["sequence"] || 1) > after_sequence))
        |> Enum.sort_by(&(&1["sequence"] || 1))
        |> Enum.take(100)

      Stub.json(conn, 200, %{"data" => events})
    end)

    Gaoxy.Test.stub(server, "POST", "/api/agent/projects/project-1/tasks", fn conn ->
      {body, conn} = Stub.body(conn)
      assert_reserved!(body)

      task =
        Agent.get_and_update(state, fn current ->
          id = Enum.at([@root, @one, @two], map_size(current.tasks))

          task =
            body
            |> Map.drop(["command_id"])
            |> Map.merge(%{
              "id" => id,
              "version" => 1,
              "state" => "open",
              "artifact_references" => []
            })

          event = %{
            "type" => "task.created",
            "resource_id" => id,
            "command_id" => body["command_id"]
          }

          {task,
           %{
             current
             | tasks: Map.put(current.tasks, id, task),
               writes: current.writes ++ [{:create, body}],
               events: [event | current.events]
           }}
        end)

      send(owner, {:created, task})
      Stub.json(conn, 201, %{"data" => task})
    end)

    for id <- [@root, @one, @two] do
      Gaoxy.Test.stub(server, "GET", "/api/agent/projects/project-1/tasks/#{id}", fn conn ->
        Stub.json(conn, 200, %{"data" => Agent.get(state, &Map.fetch!(&1.tasks, id))})
      end)

      Gaoxy.Test.stub(
        server,
        "POST",
        "/api/agent/projects/project-1/tasks/#{id}/assign",
        fn conn ->
          {body, conn} = Stub.body(conn)
          assert_reserved!(body)

          task =
            Agent.get_and_update(state, fn current ->
              task = current.tasks[id]
              assert task["version"] == body["expected_version"]

              task =
                Map.merge(task, %{
                  "version" => task["version"] + 1,
                  "assignee_agent_id" => body["assignee_agent_id"]
                })

              event = %{
                "type" => "task.assigned",
                "resource_id" => id,
                "command_id" => body["command_id"]
              }

              {task,
               %{
                 current
                 | tasks: Map.put(current.tasks, id, task),
                   writes: current.writes ++ [{:assign, body}],
                   events: [event | current.events]
               }}
            end)

          send(owner, {:assigned, task})
          Stub.json(conn, 200, %{"data" => task})
        end
      )
    end

    on_exit(fn ->
      for entry <- Coordinator.list() do
        if id = get_in(entry, ["planning_session", "session_id"]) do
          Synapsis.Session.DynamicSupervisor.stop_session(id)
          Synapsis.Sessions.delete(id)
        end
      end

      for execution <- Executions.list(), id = get_in(execution, ["runtime", "session_id"]) do
        Synapsis.Session.DynamicSupervisor.stop_session(id)
        Synapsis.Sessions.delete(id)
      end

      for device <- Devices.list(), do: Inbound.disconnect(device["id"])
      Synapsis.DataCase.clear_config_store(:samgita)
      clear!()
      if Process.alive?(state), do: Agent.stop(state)
    end)

    %{server: server, state: state, url: Gaoxy.Test.url(server) |> String.trim_trailing("/")}
  end

  defp clear! do
    for prefix <- [
          "coord/samgita/coordination/",
          "coord/samgita/inbox/",
          "coord/samgita/executions/"
        ] do
      assert {:ok, %{succeeded: true}} = Concord.Turso.replace_prefix(prefix, [], timeout: 5_000)
    end
  end

  def context(roles \\ ["manager"]) do
    %{
      "memberships" => [
        %{"agent_id" => @manager, "roles" => roles, "enabled" => true},
        %{"agent_id" => @worker, "roles" => ["worker"], "enabled" => true}
      ],
      "event_routing" => %{"agent_id" => @manager, "purpose" => "responsible", "enabled" => true},
      "allowed_operations" => ["task.create"]
    }
  end

  def plan(assignee),
    do: %{
      "title" => "Prepare delivery",
      "tasks" =>
        Enum.map(
          ["Implement", "Verify"],
          &%{
            "title" => &1,
            "description" => "Complete the explicit request: " <> &1,
            "assignee_agent_id" => assignee,
            "required_capabilities" => []
          }
        )
    }

  defp event(id \\ "manual-1"),
    do: %{
      "schema_version" => "1.0",
      "event_id" => id,
      "delivery_attempt_id" => "delivery-1",
      "created_at" => "2026-11-20T00:00:00Z",
      "correlation_id" => "correlation-1",
      "project_ref" => "project-1",
      "type" => "manual.triggered",
      "payload" => %{"data" => %{"summary" => "Prepare the requested delivery"}}
    }

  defp devices(url, source_id \\ "planner", worker_source_id \\ nil) do
    {:ok, manager} = Devices.select("agent", source_id, "Manager", "synapsis", url)

    {:ok, manager} =
      Devices.record_connection(manager["id"], %{
        "id" => "connection-1",
        "agent_id" => @manager,
        "generation" => 1
      })

    {:ok, executor} =
      if worker_source_id,
        do: Devices.select("agent", worker_source_id, "Executor", "synapsis", url),
        else: Devices.select("local_agent", "fixture-executor", "Executor", "codex", url)

    {:ok, _} =
      Devices.record_connection(executor["id"], %{
        "id" => "worker-connection",
        "agent_id" => @worker,
        "generation" => 1
      })

    manager
  end

  defp opts(device),
    do: [
      planner: Planner,
      connection: fn ->
        {:ok,
         %{
           base_url: device["base_url"],
           credential: "fixture-token",
           agent_id: @manager,
           connection_id: "connection-1"
         }}
      end
    ]

  defp install_execution_callbacks(server, state, owner) do
    Gaoxy.Test.stub(server, "POST", "/api/agent/projects/project-1/sessions", fn conn ->
      {body, conn} = Stub.body(conn)
      assert is_binary(body["command_id"])
      Stub.json(conn, 201, %{"data" => %{"id" => Ecto.UUID.generate()}})
    end)

    for task_id <- [@one, @two] do
      attempt_id = "attempt-#{task_id}"

      Gaoxy.Test.stub(
        server,
        "POST",
        "/api/agent/projects/project-1/tasks/#{task_id}/claim",
        fn conn ->
          {body, conn} = Stub.body(conn)
          assert body["expected_version"] == 2
          Agent.update(state, &put_in(&1, [:tasks, task_id, "state"], "in_progress"))

          Stub.json(conn, 201, %{
            "data" => %{"id" => attempt_id, "version" => 1, "state" => "leased"}
          })
        end
      )

      Gaoxy.Test.stub(
        server,
        "GET",
        "/api/agent/projects/project-1/attempts/#{attempt_id}/proof",
        fn conn ->
          Stub.json(conn, 200, %{"data" => %{"proof" => "fixture-owner-proof"}})
        end
      )

      for {action, version} <- [{"start", 2}, {"progress", 3}] do
        Gaoxy.Test.stub(
          server,
          "POST",
          "/api/agent/projects/project-1/attempts/#{attempt_id}/#{action}",
          fn conn ->
            {body, conn} = Stub.body(conn)
            assert body["proof"] == "fixture-owner-proof"
            assert body["expected_version"] == version - 1

            Stub.json(conn, 200, %{
              "data" => %{"id" => attempt_id, "version" => version, "state" => "running"}
            })
          end
        )
      end

      Gaoxy.Test.stub(
        server,
        "POST",
        "/api/agent/projects/project-1/attempts/#{attempt_id}/report",
        fn conn ->
          {body, conn} = Stub.body(conn)
          assert body["expected_version"] == 3
          assert body["outcome"] == "succeeded"
          assert body["effects_resolved"] == true
          assert body["result"]["summary"] == "Executed and verified the requested task"

          artifact = %{
            "id" => "artifact-#{attempt_id}",
            "task_id" => task_id,
            "attempt_id" => attempt_id,
            "kind" => "file",
            "locator" => "evidence/#{task_id}.txt",
            "digest" => "sha256:fixture"
          }

          Agent.update(state, fn current ->
            put_in(
              current,
              [:tasks, task_id],
              Map.merge(current.tasks[task_id], %{
                "state" => "awaiting_review",
                "version" => 4,
                "artifact_references" => [
                  artifact,
                  Map.put(artifact, "attempt_id", "other-attempt")
                ]
              })
            )
          end)

          reported =
            event("reported-#{attempt_id}")
            |> Map.merge(%{
              "type" => "attempt.reported",
              "task_ref" => task_id,
              "payload" => %{
                "resource_type" => "attempt",
                "resource_id" => attempt_id,
                "data" => %{
                  "task_id" => task_id,
                  "state" => "succeeded",
                  "task_after" => %{"state" => "awaiting_review", "version" => 4}
                }
              }
            })

          send(owner, {:attempt_reported, reported})

          Stub.json(conn, 200, %{
            "data" => %{"id" => attempt_id, "state" => "succeeded", "version" => 4}
          })
        end
      )
    end
  end

  defp assert_reserved!(body) do
    entries = Coordination.list()

    assert Enum.any?(entries, fn entry ->
             Enum.any?(entry["commands"], fn {_, command} ->
               command["command_id"] == body["command_id"] && command["status"] == "requested"
             end)
           end)
  end

  test "durable commands create one tree and duplicate inputs cannot replan", %{
    url: url,
    state: state
  } do
    device = devices(url)
    {:ok, :new, entry} = Coordination.enqueue(device["id"], event())

    assert {:ok, %{"phase" => "awaiting_results", "children" => children}} =
             Worker.run(entry, opts(device))

    assert map_size(children) == 2
    assert Enum.all?(Map.values(children), &(&1["assignee_agent_id"] == @worker))

    assert [
             {:create, _},
             {:create, %{"parent_task_id" => @root}},
             {:assign, _},
             {:create, %{"parent_task_id" => @root}},
             {:assign, _}
           ] = Agent.get(state, & &1.writes)

    {:ok, :existing, repeated} = Coordination.enqueue(device["id"], event())
    assert :ok = Worker.run(repeated, opts(device))
    assert Process.get(:plans) == 1
    assert length(Agent.get(state, & &1.writes)) == 5
  end

  test "non-manager and invalid assignees make no management writes", %{url: url, state: state} do
    device = devices(url)
    Agent.update(state, &%{&1 | roles: ["worker"]})
    {:ok, :new, entry} = Coordination.enqueue(device["id"], event())

    assert {:ok, %{"phase" => "blocked", "last_error" => "responsible_manager_required"}} =
             Worker.run(entry, opts(device))

    assert Agent.get(state, & &1.writes) == []
    assert {:error, :invalid_plan} = Worker.validate_plan(plan("outside-project"), [@worker])

    assert {:error, :invalid_plan} =
             Worker.validate_plan(
               put_in(plan(@worker), ["tasks", Access.at(0), "required_capabilities"], ["unknown"]),
               [@worker]
             )
  end

  test "interrupted create reconciles the stored command receipt without replay or decomposition",
       %{url: url, state: state} do
    device = devices(url)
    {:ok, :new, entry} = Coordination.enqueue(device["id"], event())
    command_id = Ecto.UUID.generate()
    root = %{"id" => @root, "version" => 1, "state" => "open"}

    Agent.update(
      state,
      &%{
        &1
        | tasks: %{@root => root},
          events:
            Enum.map(
              1..100,
              fn sequence ->
                %{
                  "type" => "task.updated",
                  "sequence" => sequence,
                  "command_id" => "other-#{sequence}"
                }
              end
            ) ++
              [
                %{
                  "type" => "task.created",
                  "resource_id" => @root,
                  "command_id" => command_id,
                  "sequence" => 101
                }
              ]
      }
    )

    {:ok, entry} =
      Coordination.update(
        entry["id"],
        &{:ok,
         Map.merge(&1, %{
           "phase" => "dispatching",
           "plan" => plan(@worker),
           "commands" => %{
             "root" => %{
               "command_id" => command_id,
               "status" => "requested",
               "operation" => "create",
               "payload" => %{"title" => "Prepare delivery"}
             }
           }
         })}
      )

    assert {:ok, %{"phase" => "awaiting_results"}} = Worker.run(entry, opts(device))
    refute Process.get(:plans)
    assert_receive {:event_page, 0}
    assert_receive {:event_page, 100}

    assert [{:create, _}, {:assign, _}, {:create, _}, {:assign, _}] =
             Agent.get(state, & &1.writes)

    assert {:ok, stored} = Coordination.get(entry["id"])
    assert stored["commands"]["root"]["command_id"] == command_id
  end

  test "uncertain assignment cannot use coincidental assignee state as its receipt", %{
    url: url,
    state: state
  } do
    device = devices(url)
    {:ok, :new, entry} = Coordination.enqueue(device["id"], event())
    assert {:ok, done} = Worker.run(entry, opts(device))
    first = done["commands"]["child-1:assign"]

    Agent.update(
      state,
      &%{
        &1
        | events:
            Enum.reject(&1.events, fn event -> event["command_id"] == first["command_id"] end)
      }
    )

    {:ok, interrupted} =
      Coordination.update(entry["id"], fn current ->
        {:ok,
         current
         |> Map.put("phase", "dispatching")
         |> put_in(["commands", "child-1:assign", "status"], "requested")}
      end)

    assert {:ok,
            %{"phase" => "recovery_required", "last_error" => "assignment_outcome_unconfirmed"}} =
             Worker.run(interrupted, opts(device))

    assert length(Agent.get(state, & &1.writes)) == 5
    assert Process.get(:plans) == 1
  end

  test "an older report cannot replace a newer attempt when both reads see the same Task version",
       %{url: url, state: state} do
    device = devices(url)
    {:ok, :new, parent} = Coordination.enqueue(device["id"], event())
    assert {:ok, _} = Worker.run(parent, opts(device))
    artifact = %{"attempt_id" => "new-attempt", "kind" => "file", "locator" => "verified/new.txt"}

    Agent.update(state, fn current ->
      put_in(
        current,
        [:tasks, @one],
        Map.merge(current.tasks[@one], %{
          "state" => "awaiting_review",
          "version" => 8,
          "artifact_references" => [artifact]
        })
      )
    end)

    for {attempt, sequence} <- [{"new-attempt", 20}, {"old-attempt", 19}] do
      report =
        event("event-#{attempt}")
        |> Map.merge(%{
          "type" => "attempt.reported",
          "task_ref" => @one,
          "payload" => %{
            "sequence" => sequence,
            "resource_type" => "attempt",
            "resource_id" => attempt,
            "data" => %{"task_id" => @one, "state" => "succeeded"}
          }
        })

      {:ok, :new, entry} = Coordination.enqueue(device["id"], report)
      assert {:ok, %{"phase" => "completed"}} = Worker.run(entry, opts(device))
    end

    {:ok, stored} = Coordination.get(parent["id"])

    assert %{
             "attempt_id" => "new-attempt",
             "report_sequence" => 20,
             "artifact_references" => [^artifact]
           } = stored["children"]["child-1"]
  end

  test "journal history continues past a bounded Concord page" do
    assert {:ok, :new, _} = Coordination.enqueue("a-device", event("outside-low"))
    assert {:ok, :new, _} = Coordination.enqueue("z-device", event("outside-high"))

    for index <- 1..101 do
      assert {:ok, :new, _} = Coordination.enqueue("paged-device", event("page-#{index}"))
    end

    entries = Coordination.list("paged-device")

    assert length(entries) == 101

    assert MapSet.new(entries, &{&1["device_id"], &1["event_id"]}) ==
             MapSet.new(1..101, &{"paged-device", "page-#{&1}"})
  end

  @tag :functional
  @tag :tmp_dir
  test "native WebSocket manual event plans through the real provider and exposes server report evidence",
       %{url: http_url, server: _server, state: state, tmp_dir: dir} do
    alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
    harness = SessionHarness.setup_session!(tmp_dir: dir, install_provider?: false)
    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: ["memory::search"],
               config: %{
                 "workspace_path" => dir,
                 "mcp_selection" => %{"default" => "all", "sources" => %{}}
               }
             })

    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {request, conn} = Stub.body(conn)
      planner? = JSON.encode!(request) =~ "Decompose this explicit Samgita project request"
      assert Map.get(request, "tools", []) == []
      Agent.update(state, &Map.update(&1, :provider_calls, 1, fn count -> count + 1 end))
      send(owner, if(planner?, do: :planner_requested, else: :executor_requested))

      text =
        if planner?,
          do: JSON.encode!(plan(@worker)),
          else: "Executed and verified the requested task"

      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(text),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    {:ok, executor_config} =
      Synapsis.AgentConfigs.create(%{
        name: "coordinator-executor-#{System.unique_integer([:positive])}",
        provider: harness.provider.name,
        model: "characterization-model",
        tools: [],
        tool_contract_version: 1,
        config: %{"workspace_path" => dir}
      })

    on_exit(fn -> Synapsis.AgentConfigs.delete(executor_config) end)

    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: :coordinator_fixture,
         plug: {Host, [test: self(), http_url: http_url]},
         ip: {127, 0, 0, 1},
         port: 0}
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(listener, :coordinator_fixture)
    device = devices("http://127.0.0.1:#{port}", harness.agent_config.id, executor_config.id)
    # This device has a confirmed registration; native bootstrap establishes a new generation.
    assert {:ok, _} = Inbound.connect(device["id"])
    assert_receive {:bootstrap, socket, _}, 3_000

    send(
      socket,
      {:approve,
       %{
         "id" => "connection-2",
         "agent_id" => @manager,
         "generation" => 2,
         "expires_at" => "2099-01-01T00:00:00Z"
       }}
    )

    assert_receive {:native_ready, ^socket}, 3_000
    executor = Enum.find(Devices.list(), &(&1["agent_id"] == @worker))
    assert {:ok, _} = Inbound.connect(executor["id"])
    assert_receive {:bootstrap, worker_socket, _}, 3_000

    send(
      worker_socket,
      {:approve,
       %{
         "id" => "worker-connection-2",
         "agent_id" => @worker,
         "generation" => 2,
         "expires_at" => "2099-01-01T00:00:00Z"
       }}
    )

    assert_receive {:native_ready, ^worker_socket}, 3_000
    send(socket, {:request, "project/event.receive", %{"event" => event()}, "native-manual"})

    assert_receive {:host_response, ^socket, "project/event.receive",
                    {:ok, %{"acceptance" => "durable"}}, _},
                   3_000

    assert_receive :planner_requested, 10_000

    for task_id <- [@one, @two] do
      assert_receive {:assigned, %{"id" => ^task_id, "assignee_agent_id" => @worker}}, 20_000

      assigned =
        event("assigned-#{task_id}")
        |> Map.merge(%{"type" => "task.assigned", "task_ref" => task_id})

      send(
        worker_socket,
        {:request, "project/event.receive", %{"event" => assigned}, "execute-#{task_id}"}
      )

      assert_receive {:host_response, ^worker_socket, "project/event.receive",
                      {:ok, %{"acceptance" => "durable"}}, _},
                     3_000
    end

    await(fn -> match?([%{"phase" => "awaiting_results"}], Coordinator.list(device["id"])) end)
    assert :ok = Supervisor.terminate_child(SynapsisSamgita.Supervisor, Coordinator)
    assert {:ok, _} = Supervisor.restart_child(SynapsisSamgita.Supervisor, Coordinator)
    send(socket, {:request, "project/event.receive", %{"event" => event()}, "native-duplicate"})
    assert_receive {:host_response, ^socket, "project/event.receive", {:ok, _}, _}, 3_000

    for task_id <- [@one, @two] do
      assert_receive {:attempt_reported, %{"task_ref" => ^task_id} = reported}, 20_000

      send(
        socket,
        {:request, "project/event.receive", %{"event" => reported}, "reported-#{task_id}"}
      )

      assert_receive {:host_response, ^socket, "project/event.receive", {:ok, _}, _}, 3_000
    end

    await(fn ->
      match?([%{"phase" => "awaiting_human_review"}], Coordinator.list(device["id"]))
    end)

    [entry] = Coordinator.list(device["id"])

    for {_, child} <- entry["children"] do
      assert child["task_state"] == "awaiting_review"
      assert child["attempt_state"] == "succeeded"
      assert [%{"attempt_id" => id}] = child["artifact_references"]
      assert id == child["attempt_id"]
      assert child["evidence_scope"] == "local_execution_report"
      assert child["result"]["summary"] == "Executed and verified the requested task"
      assert is_binary(child["result"]["runtime"]["session_id"])
    end

    assert length(Agent.get(state, & &1.writes)) == 5
    assert Agent.get(state, & &1.provider_calls) == 3
    refute_receive :planner_requested, 100
    assert {:ok, %{"processing_status" => "completed"}} = Inbox.get("manual-1", device["id"])
  end

  defp await(fun, count \\ 100)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, count) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          await(fun, count - 1)
        )
  end
end
