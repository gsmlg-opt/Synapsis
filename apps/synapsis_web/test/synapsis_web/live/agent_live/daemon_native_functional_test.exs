defmodule SynapsisWeb.AgentLive.DaemonNativeFunctionalTest do
  use SynapsisWeb.ConnCase, async: false
  @moduletag :functional

  import SynapsisWeb.ReactFormHelpers

  alias SynapsisWeb.AgentLive.Daemon, as: Page
  alias Synapsis.Agent.{Daemon, Runs}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult

  @moduletag :tmp_dir
  @state_key :daemon_native_ui_functional

  defmodule AgentsStub do
    def list_enabled do
      [
        %{
          name: "linked-agent",
          label: "Configured linked Agent",
          tool_contract_version: 0,
          toolset_ids: ["native-toolset"],
          provider: "fixture"
        },
        %{name: "plain-agent", label: nil, tool_contract_version: 1}
      ]
    end
  end

  defmodule DaemonStub do
    def status, do: %{ready: true, queued_count: 0}

    def submit(prompt, opts) do
      owner = Application.fetch_env!(:synapsis_web, :daemon_native_ui_functional)
      send(owner, {:submitted, self(), prompt, opts})

      receive do
        :complete -> {:ok, %{id: "ui-run"}}
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end
  end

  defmodule EmptyStub do
    def list_recent(_), do: []
    def list, do: []
    def list(nil), do: []
  end

  defmodule RoutinesStub do
    def list(nil), do: []

    def create(attrs) do
      owner = Application.fetch_env!(:synapsis_web, :daemon_native_ui_functional)
      send(owner, {:created, self(), attrs})

      receive do
        :complete -> {:ok, %{"id" => "ui-routine"}}
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end
  end

  setup do
    previous = Application.get_env(:synapsis_web, Page, :missing)
    owner = Application.get_env(:synapsis_web, @state_key, :missing)
    Application.put_env(:synapsis_web, @state_key, self())

    Application.put_env(:synapsis_web, Page,
      daemon: DaemonStub,
      runs: EmptyStub,
      routines: RoutinesStub,
      backplane: EmptyStub,
      agents: AgentsStub
    )

    on_exit(fn ->
      restore_env(Page, previous)
      restore_env(@state_key, owner)
    end)

    :ok
  end

  test "managed choices project configured names and labels and retain existing defaults", %{
    conn: conn
  } do
    {:ok, view, _} = live_isolated(conn, Page)

    expected_agents = [
      %{"value" => "", "label" => "Default Agent"},
      %{"value" => "linked-agent", "label" => "Configured linked Agent"},
      %{"value" => "plain-agent", "label" => "plain-agent"}
    ]

    assert field(view, "manual-run-form", "manual[assistant_name]")["options"] == expected_agents
    assert field(view, "routine-create-form", "routine[agent_name]")["options"] == expected_agents
    assert field(view, "manual-run-form", "manual[assistant_name]")["label"] == "Execution Agent"
    assert field(view, "manual-run-form", "manual[tool_profile]")["label"] == "Tools"

    assert field(view, "manual-run-form", "manual[tool_profile]")["options"] == [
             %{"value" => "", "label" => "Default"},
             %{"value" => "native_agent", "label" => "Configured Agent tools"}
           ]

    assert Enum.map(
             field(view, "routine-create-form", "routine[tool_profile]")["options"],
             & &1["value"]
           ) ==
             [
               "assistant_basic",
               "assistant_workspace",
               "assistant_coding",
               "assistant_dream",
               "native_agent"
             ]

    assert values(view, "manual-run-form") == %{"manual" => manual_defaults()}
    assert values(view, "routine-create-form")["routine"]["agent_name"] == ""
    assert values(view, "routine-create-form")["routine"]["tool_profile"] == "assistant_basic"

    react_form_submit(view, "manual-run-form", %{"manual" => %{"prompt" => "Default task"}})
    assert_receive {:submitted, pid, "Default task", opts}
    assert opts == %{source: "web"}
    send(pid, :complete)
    assert render_async(view) =~ "Run queued"

    routine = %{
      "name" => "Default routine",
      "kind" => "schedule",
      "schedule" => "0 0 1 1 *",
      "tool_profile" => "assistant_basic",
      "prompt" => "Default routine task",
      "enabled" => "true"
    }

    react_form_submit(view, "routine-create-form", %{"routine" => routine})
    assert_receive {:created, pid, attrs}
    assert attrs == Map.put(routine, "enabled", true)
    send(pid, :complete)
    assert render_async(view) =~ "Routine created"
  end

  test "typed selections survive refresh and loading remounts and successful forms fully reset",
       %{conn: conn} do
    {:ok, view, _} = live_isolated(conn, Page)

    manual = %{
      "prompt" => "Typed native task",
      "assistant_name" => "linked-agent",
      "tool_profile" => "native_agent"
    }

    routine = %{
      "name" => "Typed routine",
      "kind" => "schedule",
      "schedule" => "0 0 1 1 *",
      "agent_name" => "linked-agent",
      "tool_profile" => "native_agent",
      "prompt" => "Typed routine task",
      "enabled" => "true"
    }

    react_form_change(view, "manual-run-form", %{"manual" => manual})
    react_form_change(view, "routine-create-form", %{"routine" => routine})
    send(view.pid, {:agent_daemon_event, %{event: "agent.run.completed"}})
    assert values(view, "manual-run-form") == %{"manual" => manual}
    assert values(view, "routine-create-form") == %{"routine" => routine}

    react_form_submit(view, "manual-run-form", %{"manual" => manual})
    assert_receive {:submitted, pid, "Typed native task", opts}
    assert opts == %{source: "web", assistant_name: "linked-agent", tool_profile: "native_agent"}
    assert render(view) =~ "Queueing run"
    assert values(view, "manual-run-form") == %{"manual" => manual}
    assert values(view, "routine-create-form") == %{"routine" => routine}
    send(pid, :complete)
    assert render_async(view) =~ "Run queued"
    assert values(view, "manual-run-form") == %{"manual" => manual_defaults()}
    assert values(view, "routine-create-form") == %{"routine" => routine}

    react_form_submit(view, "routine-create-form", %{"routine" => routine})
    assert_receive {:created, pid, attrs}
    assert attrs == Map.put(routine, "enabled", true)
    assert render(view) =~ "Creating routine"
    assert values(view, "routine-create-form") == %{"routine" => routine}
    send(pid, :complete)
    assert render_async(view) =~ "Routine created"

    assert values(view, "routine-create-form") == %{
             "routine" => %{
               "name" => "",
               "kind" => "schedule",
               "schedule" => "0 * * * *",
               "agent_name" => "",
               "tool_profile" => "assistant_basic",
               "prompt" => "",
               "enabled" => true
             }
           }
  end

  test "manual native submit executes the production daemon and persists the following tool result",
       ctx do
    saved = native_fixture(ctx.tmp_dir, "manual")
    use_production()
    {:ok, view, _} = live_isolated(ctx.conn, Page)

    react_form_submit(view, "manual-run-form", %{
      "manual" => %{
        "prompt" => "Native manual UI task",
        "assistant_name" => saved.name,
        "tool_profile" => "native_agent"
      }
    })

    assert render_async(view) =~ "Run queued"
    run = await_run(saved.name)
    assert run.kind == "manual"
    assert run.source == "web"
    assert_native_run(run, saved, ctx.tmp_dir, "manual")
  end

  test "stored native routine runs through the default scheduler and preserves a saved legacy routine",
       ctx do
    saved = native_fixture(ctx.tmp_dir, "routine")
    legacy = stored_legacy()
    use_production()
    {:ok, view, _} = live_isolated(ctx.conn, Page)
    assert has_element?(view, "#routine-#{legacy["id"]}", "assistant_coding")
    name = "native-ui-#{Ecto.UUID.generate()}"

    react_form_submit(view, "routine-create-form", %{
      "routine" => %{
        "name" => name,
        "kind" => "schedule",
        "schedule" => "0 0 1 1 *",
        "agent_name" => saved.name,
        "tool_profile" => "native_agent",
        "prompt" => "Native routine UI task",
        "enabled" => "true"
      }
    })

    assert render_async(view) =~ "Routine created"
    routine = Enum.find(Synapsis.Agent.Routines.list(), &(&1["name"] == name))
    assert routine["agent_name"] == saved.name
    assert routine["tool_profile"] == "native_agent"
    cleanup_routine(routine["id"])
    scheduler = Process.whereis(LocalScheduler)
    assert is_pid(scheduler)
    assert :sys.get_state(scheduler).timers[{"routine", routine["id"]}]

    view
    |> element("#routine-#{routine["id"]} [phx-click='trigger_routine']", "Run now")
    |> render_click()

    assert render_async(view) =~ "Routine queued"
    run = await_run(saved.name)
    assert run.kind == "schedule"
    assert run.routine_id == routine["id"]
    assert_native_run(run, saved, ctx.tmp_dir, "routine")

    await(fn ->
      match?({:ok, %{"last_status" => "completed"}}, ConfigStore.get(:routine, routine["id"]))
    end)

    assert {:ok, persisted} = ConfigStore.get(:routine, routine["id"])
    assert persisted["agent_name"] == saved.name
    assert persisted["tool_profile"] == "native_agent"
    assert is_binary(persisted["last_run_at"])
    assert is_binary(persisted["next_run_at"])
    assert Process.whereis(LocalScheduler) == scheduler
    assert {:ok, ^legacy} = ConfigStore.get(:routine, legacy["id"])
  end

  defp use_production do
    Application.put_env(:synapsis_web, Page, backplane: EmptyStub)
    await(fn -> Daemon.status().ready end)
  end

  defp native_fixture(root, label) do
    fixture = Gaoxy.Test.open()
    provider = "native-ui-#{Ecto.UUID.generate()}"
    owner = self()

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               label: "Native UI Agent",
               provider: provider,
               model: "native-ui-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))
      send(owner, {:native_ui_request, label, following?, request})

      delta =
        if following?,
          do: %{"content" => "Native UI complete"},
          else: %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "ui-call",
                "type" => "function",
                "function" => %{
                  "name" => "exec_command",
                  "arguments" =>
                    Jason.encode!(%{
                      "cmd" => "printf effect >> #{label}.txt",
                      "login" => false,
                      "yield_time_ms" => 1000
                    })
                }
              }
            ]
          }

      chunks = [
        %{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]},
        %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{},
              "finish_reason" => if(following?, do: "stop", else: "tool_calls")
            }
          ]
        }
      ]

      body =
        Enum.map_join(chunks, "\n\n", &("data: " <> Jason.encode!(&1))) <> "\n\ndata: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    saved
  end

  defp stored_legacy do
    assert {:ok, legacy} =
             ConfigStore.put(:routine, %{
               "id" => Ecto.UUID.generate(),
               "name" => "Saved legacy routine",
               "kind" => "schedule",
               "enabled" => false,
               "schedule" => "0 0 1 1 *",
               "tool_profile" => "assistant_coding",
               "prompt" => "Existing task"
             })

    cleanup_routine(legacy["id"])
    legacy
  end

  defp cleanup_routine(id) do
    on_exit(fn ->
      ConfigStore.delete(:routine, id)
      LocalScheduler.reload()
    end)
  end

  defp await_run(name) do
    await(fn ->
      Enum.any?(
        Runs.list_recent(limit: 100),
        &(&1.assistant_name == name and &1.status == "completed")
      )
    end)

    Enum.find(Runs.list_recent(limit: 100), &(&1.assistant_name == name))
  end

  defp assert_native_run(run, saved, root, label) do
    assert run.tool_profile == "native_agent"
    assert run.assistant_name == saved.name
    assert run.capability_snapshot["agent_id"] == saved.id
    assert run.capability_snapshot["tool_names"] == ["exec_command"]
    assert run.status == "completed"
    assert run.finished_at
    assert_receive {:native_ui_request, ^label, false, first}, 5_000
    assert Enum.map(first["tools"], & &1["function"]["name"]) == ["exec_command"]
    assert_receive {:native_ui_request, ^label, true, following}, 5_000
    assert File.read!(Path.join(root, "#{label}.txt")) == "effect"

    assert [%ToolResult{is_error: false} = result] =
             for(
               message <- Synapsis.Sessions.get_messages(run.session_id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    assert %{"role" => "tool", "tool_call_id" => result.tool_use_id, "content" => result.content} in following[
             "messages"
           ]

    assert {:ok, turns} = Synapsis.Session.Store.list_turns(run.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert {:ok, ^run} = Runs.fetch(run.id)
  end

  defp await(fun, attempts \\ 300)
  defp await(_fun, 0), do: flunk("native UI condition timed out")

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          await(fun, attempts - 1)
        )
  end

  defp field(view, id, name) do
    view
    |> element("[data-form-id='#{id}']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-dm-react-field]")
    |> LazyHTML.attribute("data-dm-react-field")
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["name"] == name))
  end

  defp values(view, id) do
    view
    |> element("[data-form-id='#{id}']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-form-id]")
    |> LazyHTML.attribute("data-initial-values")
    |> hd()
    |> Jason.decode!()
  end

  defp manual_defaults, do: %{"prompt" => "", "assistant_name" => "", "tool_profile" => ""}
  defp restore_env(key, :missing), do: Application.delete_env(:synapsis_web, key)
  defp restore_env(key, value), do: Application.put_env(:synapsis_web, key, value)
end
