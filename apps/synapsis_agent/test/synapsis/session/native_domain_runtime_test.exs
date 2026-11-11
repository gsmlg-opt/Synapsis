defmodule Synapsis.Session.NativeDomainRuntimeTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}

  alias Synapsis.Agent.Tools.{Filesystem, MemoryDomain, SessionState, SessionSummary}

  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_dir = System.get_env("SYNAPSIS_MEMORY_DIR")
    System.put_env("SYNAPSIS_MEMORY_DIR", Path.join(tmp_dir, "records"))
    Synapsis.Memory.Cache.clear()

    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      if previous_dir,
        do: System.put_env("SYNAPSIS_MEMORY_DIR", previous_dir),
        else: System.delete_env("SYNAPSIS_MEMORY_DIR")

      Synapsis.Memory.Cache.clear()
    end)

    SessionHarness.subscribe!(harness.session.id)
    %{harness: harness, id: harness.session.id}
  end

  test "all native filesystem actions execute through Worker and retain rich durable results",
       ctx do
    select(ctx, Filesystem.names())

    calls = [
      {"synapsis::write", %{"path" => "first.txt", "content" => "one\n"}},
      {"synapsis::edit",
       %{"path" => "first.txt", "edits" => [%{"oldText" => "one", "newText" => "two"}]}},
      {"synapsis::read", %{"path" => "first.txt"}},
      {"synapsis::ls", %{"path" => "."}}
    ]

    runtime = run(ctx, calls)
    descriptors = runtime.descriptors
    assert Enum.sort(Map.keys(descriptors)) == Enum.sort(Filesystem.names())
    assert Enum.all?(descriptors, fn {_, descriptor} -> descriptor.backend == Filesystem end)
    results = results(ctx.id)
    assert length(results) == 4
    assert Enum.all?(results, &(&1.is_error == false and is_map(&1.projection)))
    assert Enum.at(results, 2).content =~ "two"
    assert Enum.at(results, 3).content =~ "first.txt"
    assert length(intents(runtime)) == 4
    assert File.read!(Path.join(ctx.harness.tmp_dir, "first.txt")) == "two\n"

    assert {:ok, turns} = Store.list_turns(ctx.id)
    durable = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert Enum.map(durable, & &1[:projection]) == Enum.map(results, & &1.projection)
  end

  test "native file read and search do not require shell execution authority", ctx do
    select(ctx, ~w(synapsis::read synapsis::ls))
    permission(ctx, allow_execute: :deny)
    File.write!(Path.join(ctx.harness.tmp_dir, "read.txt"), "bounded native content\n")

    runtime =
      run(ctx, [
        {"synapsis::read", %{"path" => "read.txt"}},
        {"synapsis::ls", %{"path" => "."}}
      ])

    assert [%ToolResult{is_error: false, content: text}, %ToolResult{is_error: false}] =
             results(ctx.id)

    assert text =~ "bounded native content"
    assert length(intents(runtime)) == 2
  end

  test "write denial blocks the native intent and filesystem effect", ctx do
    select(ctx, ["synapsis::write"])
    permission(ctx, allow_write: :deny)
    runtime = run(ctx, [{"synapsis::write", %{"path" => "denied.txt", "content" => "no"}}])
    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
    refute File.exists?(Path.join(ctx.harness.tmp_dir, "denied.txt"))
  end

  test "Workspace files use persisted agent name and session ownership", ctx do
    select(ctx, ~w(synapsis::write synapsis::read))
    logical = "/agents/#{ctx.harness.agent_name}/sessions/#{ctx.id}/native-note.md"
    path = "@synapsis" <> logical

    runtime =
      run(ctx, [
        {"synapsis::write", %{"path" => path, "content" => "owned Workspace content"}},
        {"synapsis::read", %{"path" => path}}
      ])

    assert {:ok, %{content: "owned Workspace content"}} = Synapsis.Workspace.read(logical)

    assert [%ToolResult{is_error: false}, %ToolResult{is_error: false, content: text}] =
             results(ctx.id)

    assert text =~ "owned Workspace content"

    context = runtime.descriptors["synapsis::write"].backend_context

    assert context.workspace == %{
             role: :session,
             agent_id: ctx.harness.agent_name,
             session_id: ctx.id
           }

    refute context.workspace.agent_id == ctx.harness.agent_config.id
    assert length(intents(runtime)) == 2
  end

  test "foreign Workspace ownership is rejected before native intent", ctx do
    select(ctx, ["synapsis::write"])

    runtime =
      run(ctx, [
        {"synapsis::write", %{"path" => "@synapsis/agents/foreign/private.md", "content" => "no"}}
      ])

    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
  end

  test "semantic memory uses persisted UUID while default search reads workspace Markdown", ctx do
    names = ~w(synapsis::memory_save synapsis::memory_source_search synapsis::memory_update)
    select(ctx, names)
    File.write!(Path.join(ctx.harness.tmp_dir, "MEMORY.md"), "# Memory\nConcord is embedded.\n")

    runtime =
      run(ctx, [
        {"synapsis::memory_save",
         %{
           "memories" => [
             %{
               "kind" => "fact",
               "title" => "Concord record",
               "summary" => "Saved semantic content"
             }
           ]
         }},
        {"synapsis::memory_source_search", %{"query" => "Concord"}},
        {"synapsis::memory_source_search", %{"source" => "records", "query" => "Concord"}}
      ])

    assert [saved, markdown, records] = results(ctx.id)
    assert Enum.all?([saved, markdown, records], &(&1.is_error == false))

    assert [%{"id" => id, "status" => "saved"}] =
             saved.projection["result"]["structured"]["results"]

    assert {:ok, record} = Synapsis.Memory.get_semantic(id)
    assert record.scope_id == ctx.harness.agent_config.id
    assert record.contributed_by == ctx.harness.agent_config.id
    refute record.scope_id == runtime.run_id
    refute record.scope_id == ctx.harness.agent_name
    assert markdown.content =~ "MEMORY.md:2-2"
    assert records.content =~ "Concord record"
    descriptor = runtime.descriptors["synapsis::memory_save"]
    assert descriptor.backend == MemoryDomain
    assert descriptor.backend_context.project_id == nil
    assert length(intents(runtime)) == 3
  end

  test "semantic memory mutations honor write denial before persistence", ctx do
    select(ctx, ["synapsis::memory_save"])
    permission(ctx, allow_write: :deny)

    runtime =
      run(ctx, [
        {"synapsis::memory_save",
         %{"memories" => [%{"kind" => "fact", "title" => "Denied", "summary" => "No effect"}]}}
      ])

    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
    assert Path.wildcard(Path.join(ctx.harness.tmp_dir, "records/**/*.md")) == []
  end

  @tag :model_visible_result
  test "native todo and planning intent preserve durable session state and events", ctx do
    select(ctx, SessionState.names())

    todos = [
      %{"id" => "second", "content" => "Keep supplied order", "status" => "in_progress"},
      %{"id" => "first", "content" => "Keep supplied IDs", "status" => "pending"}
    ]

    runtime =
      run(ctx, [
        {"synapsis::todo_write", %{"todos" => todos}},
        {"synapsis::todo_read", %{}}
      ])

    assert [write, read] = results(ctx.id)
    assert Enum.all?([write, read], &(&1.is_error == false))

    assert Enum.map(read.projection["result"]["structured"]["todos"], & &1["id"]) ==
             ["second", "first"]

    assert_public_replay(ctx, read)

    assert Enum.map(Store.get_value(ctx.id, "todos"), & &1["todo_id"]) == ["second", "first"]
    assert_receive {:todo_update, _, _}
    assert length(intents(runtime)) == 2
    assert Enum.all?(runtime.descriptors, fn {_, d} -> d.backend == SessionState end)
  end

  test "exact none-level todo override prevents persistence and native intent", ctx do
    select(ctx, ["synapsis::todo_write"])
    permission(ctx, tool_overrides: %{"synapsis::todo_write" => :deny})
    runtime = run(ctx, [{"synapsis::todo_write", %{"todos" => []}}])
    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert Store.get_value(ctx.id, "todos", :absent) == :absent
    assert intents(runtime) == []
    refute_receive {:todo_update, _, _}
  end

  @tag :model_visible_result
  test "native summary uses the current Worker turn and persists candidates without saving memories",
       ctx do
    select(ctx, SessionSummary.names())
    before = Synapsis.Memory.list_semantic()

    runtime =
      run(
        ctx,
        [{"synapsis::session_summarize", %{"use_llm" => false, "focus" => "native result"}}],
        message: String.duplicate("Remember these useful engineering observations. ", 3)
      )

    assert [%ToolResult{is_error: false, projection: projection} = result] = results(ctx.id)
    assert projection["result"]["structured"]["source"] == "live_session"
    assert projection["result"]["structured"]["message_count"] > 0
    assert [_ | _] = projection["result"]["structured"]["candidates"]
    assert result.content =~ "candidates were not saved"
    assert_public_replay(ctx, result)
    assert Synapsis.Memory.list_semantic() == before
    assert runtime.descriptors["synapsis::session_summarize"].backend == SessionSummary
    assert length(intents(runtime)) == 1
    assert {:ok, turns} = Store.list_turns(ctx.id)

    assert Enum.any?(turns, fn turn ->
             Enum.any?(turn.parts, &(&1[:projection] == projection))
           end)
  end

  test "summary read denial prevents native intent", ctx do
    select(ctx, SessionSummary.names())
    permission(ctx, allow_read: :deny)
    runtime = run(ctx, [{"synapsis::session_summarize", %{"use_llm" => false}}])
    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
  end

  test "missing selected Toolset stops Worker before the provider or native effects", ctx do
    missing = Ecto.UUID.generate()

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{
               tools: ["synapsis::write"],
               toolset_ids: [missing]
             })

    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      send(owner, :unexpected_selection_provider_request)
      Plug.Conn.resp(conn, 500, "must not request")
    end)

    SessionHarness.ensure_running!(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Use the saved Toolset")
    assert_receive {:run_event, %{type: "session.failed", payload: payload}}, 5_000
    assert payload["message"] =~ "toolset"
    refute_receive :unexpected_selection_provider_request, 30
    assert results(ctx.id) == []
  end

  test "Worker preserves automatic and explicit manual Skills with durable source identity",
       ctx do
    select(ctx, ~w(synapsis::skills_search synapsis::skills_read synapsis::skill))
    {automatic, manual} = assigned_skills(ctx)
    automatic_locator = "synapsis://skills/#{automatic.id}"
    manual_locator = "synapsis://skills/#{manual.id}"

    runtime =
      run(ctx, [
        {"synapsis::skills_search", %{"query" => "review"}},
        {"synapsis::skills_read", %{"locator" => automatic_locator}},
        {"synapsis::skill", %{"locator" => manual_locator}},
        {"synapsis::skills_read", %{"locator" => manual_locator}}
      ])

    assert [search, read, explicit, denied_manual] = results(ctx.id)
    assert Enum.all?([search, read, explicit], &(&1.is_error == false))
    assert denied_manual.is_error

    assert [%{"record_id" => id, "source_authority" => "synapsis"}] =
             search.projection["result"]["structured"]["results"]

    assert id == automatic.id
    assert read.projection["result"]["structured"]["citation"] == automatic_locator
    assert explicit.projection["result"]["structured"]["citation"] == manual_locator
    assert explicit.content =~ "Manual review instructions"
    assert length(intents(runtime)) == 3
    assert runtime.descriptors["synapsis::skill"].backend == Synapsis.Agent.Tools.ExplicitSkill
    assert runtime.descriptors["synapsis::skills_read"].backend == Synapsis.Agent.Tools.Skills
    assert {:ok, turns} = Store.list_turns(ctx.id)
    durable = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert Enum.map(durable, & &1[:projection]) == Enum.map(results(ctx.id), & &1.projection)
  end

  test "exact explicit Skill denial prevents native read intent even with a manual assignment",
       ctx do
    select(ctx, ["synapsis::skill"])
    {_automatic, manual} = assigned_skills(ctx)
    permission(ctx, tool_overrides: %{"synapsis::skill" => :deny})
    runtime = run(ctx, [{"synapsis::skill", %{"name" => manual.name}}])
    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
  end

  defp assigned_skills(ctx) do
    skills =
      for {name, extra, content} <- [
            {"automatic-review", "", "Automatic review instructions"},
            {"manual-review", "disable-model-invocation: true\n", "Manual review instructions"}
          ] do
        {:ok, skill} =
          Synapsis.Skills.create(%{
            name: name,
            scope: "global",
            system_prompt_fragment:
              "---\nname: #{name}\ndescription: Assigned review\n#{extra}---\n#{content}\n"
          })

        skill
      end

    agent = Synapsis.AgentConfigs.get(ctx.harness.agent_config.id)
    {:ok, _} = Synapsis.Skills.assign_skills(agent, Enum.map(skills, & &1.id))
    on_exit(fn -> Enum.each(skills, &Synapsis.Config.Store.delete(:skill, &1.id)) end)
    List.to_tuple(skills)
  end

  @tag :agent_directory_production
  test "configured Agent directory executes through Worker and retains public durable results",
       ctx do
    enabled_name = "directory-enabled-#{ctx.id}"
    disabled_name = "directory-disabled-#{ctx.id}"
    secret = "private-directory-provider-config"

    {:ok, enabled} =
      Synapsis.AgentConfigs.create(%{
        name: enabled_name,
        label: "Directory example",
        system_prompt: secret,
        config: %{"token" => secret}
      })

    {:ok, disabled} =
      Synapsis.AgentConfigs.create(%{name: disabled_name, enabled: false})

    on_exit(fn ->
      Synapsis.AgentConfigs.delete(enabled)
      Synapsis.AgentConfigs.delete(disabled)
    end)

    select(ctx, ["synapsis::agents_list"])
    runtime = run(ctx, [{"synapsis::agents_list", %{}}])
    assert Map.keys(runtime.descriptors) == ["synapsis::agents_list"]
    descriptor = runtime.descriptors["synapsis::agents_list"]
    assert descriptor.backend == Synapsis.Agent.Tools.AgentDirectory
    assert descriptor.backend_context.requester_name == ctx.harness.agent_name
    assert descriptor.backend_context.session_id == ctx.id
    refute Map.has_key?(runtime.descriptors, "list_agents")

    assert [%ToolResult{is_error: false, projection: projection} = result] = results(ctx.id)
    public = projection["result"]["structured"]

    assert public["requester"] == %{
             "id" => ctx.harness.agent_config.id,
             "name" => ctx.harness.agent_name
           }

    assert Enum.find(public["agents"], &(&1["id"] == enabled.id)) == %{
             "id" => enabled.id,
             "name" => enabled.name,
             "label" => enabled.label,
             "configured" => true
           }

    refute Enum.any?(public["agents"], &(&1["id"] == disabled.id))
    refute Jason.encode!(public) =~ secret
    refute Map.has_key?(public, "allowAny")
    assert length(intents(runtime)) == 1

    assert {:ok, turns} = Store.list_turns(ctx.id)

    assert [%{projection: ^projection}] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    requests = Agent.get(ctx.harness.counter, & &1.provider_requests)

    replay =
      for request <- requests,
          message <- request["messages"],
          message["role"] == "tool" and message["tool_call_id"] == "domain-0",
          do: message

    assert [%{"content" => content} | _] = replay
    assert content == result.content
    assert Jason.decode!(content) == public
    refute Jason.encode!(requests) =~ secret
  end

  @tag :agent_directory_production
  test "directory read denial blocks Worker native intent and directory content", ctx do
    select(ctx, ["synapsis::agents_list"])
    permission(ctx, allow_read: :deny)
    runtime = run(ctx, [{"synapsis::agents_list", %{}}])
    assert [%ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
  end

  @tag :agent_directory_production
  test "Worker rejects model-supplied directory requester and spawning policy", ctx do
    select(ctx, ["synapsis::agents_list"])

    runtime =
      run(ctx, [
        {"synapsis::agents_list", %{"requester_name" => "foreign"}},
        {"synapsis::agents_list", %{"agent_id" => Ecto.UUID.generate()}},
        {"synapsis::agents_list", %{"allowAny" => true}}
      ])

    assert length(results(ctx.id)) == 3
    assert Enum.all?(results(ctx.id), & &1.is_error)
    assert intents(runtime) == []

    assert runtime.descriptors["synapsis::agents_list"].backend_context.requester_name ==
             ctx.harness.agent_name
  end

  @tag :automation_production
  test "Worker pages and gets routed routine and legacy heartbeat configuration with public replay",
       ctx do
    automation_sources(ctx)
    ui = automation_record(:routine, "UI missing route")

    alpha =
      automation_record(:routine, "Alpha", %{agent_name: ctx.harness.agent_name, enabled: false})

    beta = automation_record(:heartbeat, "Beta", %{agent_name: ctx.harness.agent_name})
    hidden = automation_record(:routine, "Hidden", %{agent_name: "foreign"})
    assert {:ok, expected} = Synapsis.RoutineConfigs.directory(ctx.harness.agent_name, limit: 1)
    assert [%{id: id}] = expected.routines
    assert id == alpha.id
    select(ctx, ["synapsis::automations"])

    runtime =
      run(ctx, [
        {"synapsis::automations", %{"action" => "list", "limit" => 1}},
        {"synapsis::automations", %{"action" => "list", "cursor" => expected.next_cursor}},
        {"synapsis::automations", %{"action" => "get", "source" => "heartbeat", "id" => beta.id}},
        {"synapsis::automations", %{"action" => "get", "source" => "routine", "id" => ui.id}},
        {"synapsis::automations", %{"action" => "get", "source" => "routine", "id" => hidden.id}}
      ])

    assert [first, last, get, denied_ui, denied_hidden] = results(ctx.id)
    assert Enum.all?([first, last, get], &(&1.is_error == false))
    assert denied_ui.is_error and denied_hidden.is_error
    assert first.projection["result"]["structured"] == Jason.decode!(Jason.encode!(expected))

    assert [%{"id" => beta_id, "source" => "heartbeat"}] =
             last.projection["result"]["structured"]["routines"]

    assert beta_id == beta.id
    assert get.projection["result"]["structured"]["routine"]["id"] == beta.id
    for result <- [first, last, get], do: assert_public_replay(ctx, result)
    assert length(intents(runtime)) == 5
    assert Map.keys(runtime.descriptors) == ["synapsis::automations"]
    descriptor = runtime.descriptors["synapsis::automations"]
    assert descriptor.backend == Synapsis.Agent.Tools.Automations
    assert descriptor.backend_context.requester_name == ctx.harness.agent_name
    assert descriptor.backend_context.session_id == ctx.id
    requests = Agent.get(ctx.harness.counter, & &1.provider_requests)
    refute Jason.encode!(requests) =~ "PRIVATE_AUTOMATION_PROMPT"
    assert {:ok, turns} = Store.list_turns(ctx.id)
    durable = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert Enum.map(durable, & &1[:projection]) == Enum.map(results(ctx.id), & &1.projection)
  end

  @tag :automation_production
  @tag :automation_status
  test "Worker returns the bounded scheduler status to the next model request and durable replay",
       ctx do
    name = Synapsis.Agent.Heartbeat.LocalScheduler

    unless Process.whereis(name) do
      start_supervised!(
        {name,
         config_loader: fn -> [] end,
         config_writer: fn _type, _attrs -> flunk("status must not persist configuration") end}
      )
    end

    select(ctx, ["synapsis::automations"])
    runtime = run(ctx, [{"synapsis::automations", %{"action" => "status"}}])
    assert [%ToolResult{is_error: false} = result] = results(ctx.id)

    assert %{
             "scheduler" =>
               %{
                 "engine" => "node_local",
                 "running" => true,
                 "reload_status" => status
               } = scheduler
           } = result.projection["result"]["structured"]

    assert status in ["pending", "ok", "failed"]
    assert Enum.sort(Map.keys(scheduler)) == ~w(engine reload_status running)
    assert_public_replay(ctx, result)
    assert length(intents(runtime)) == 1
    assert {:ok, turns} = Store.list_turns(ctx.id)
    durable = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert Enum.map(durable, & &1[:projection]) == [result.projection]
  end

  @tag :automation_production
  test "automation read denial prevents native execution intent", ctx do
    automation_sources(ctx)
    automation_record(:routine, "Visible", %{agent_name: ctx.harness.agent_name})
    select(ctx, ["synapsis::automations"])
    permission(ctx, allow_read: :deny)

    runtime =
      run(ctx, [
        {"synapsis::automations", %{"action" => "list"}},
        {"synapsis::automations", %{"action" => "status"}}
      ])

    assert [%ToolResult{is_error: true}, %ToolResult{is_error: true}] = results(ctx.id)
    assert intents(runtime) == []
  end

  @tag :automation_production
  test "Worker rejects forged automation requester and unsupported mutation actions",
       ctx do
    select(ctx, ["synapsis::automations"])

    calls =
      [{"synapsis::automations", %{"action" => "list", "requester_name" => "main"}}] ++
        for action <- ~w(runs add update remove run wake),
            do: {"synapsis::automations", %{"action" => action}}

    runtime = run(ctx, calls)
    assert length(results(ctx.id)) == length(calls)
    assert Enum.all?(results(ctx.id), & &1.is_error)
    assert intents(runtime) == []
  end

  defp automation_sources(ctx) do
    snapshots =
      for type <- [:routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        {type, pid, :sys.get_state(pid).load_error, :ets.tab2list(:"synapsis_config_#{type}")}
      end

    on_exit(fn ->
      for {type, pid, load_error, entries} <- snapshots do
        table = :"synapsis_config_#{type}"
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        :sys.replace_state(pid, &Map.put(&1, :load_error, load_error))
      end
    end)

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(ctx.harness.tmp_dir, "automation-config")
    File.mkdir_p!(config_dir)
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)

    try do
      for type <- [:routine, :heartbeat] do
        File.write!(Synapsis.Config.Store.file_path(type), "")
        assert :ok = Synapsis.Config.Store.reload(type)
      end
    after
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")
    end
  end

  defp automation_record(type, name, attrs \\ %{}) do
    raw =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: name,
          kind: "schedule",
          enabled: true,
          schedule: "*/5 * * * *",
          prompt: "PRIVATE_AUTOMATION_PROMPT"
        },
        attrs
      )

    assert :ets.insert(:"synapsis_config_#{type}", {raw.id, raw})
    raw
  end

  defp select(ctx, tools) do
    assert {:ok, _} = Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{tools: tools})
    SessionHarness.ensure_running!(ctx.id)
  end

  defp permission(ctx, changes) do
    raw = Store.get_value(ctx.id, "permission")
    assert :ok = Store.put_value(ctx.id, "permission", Map.merge(raw, Map.new(changes)))
  end

  defp run(ctx, calls, opts \\ []) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Agent.update(ctx.harness.counter, fn state ->
        %{state | provider_requests: state.provider_requests ++ [request]}
      end)

      completed = Enum.count(request["messages"], &(&1["role"] == "tool"))

      conn =
        if completed == 0 do
          send(owner, {:domain_request, request, self()})
          {:released, conn} = AbortableHTTP.await(conn, :release_domain_response, 5_000, owner)
          conn
        else
          conn
        end

      case Enum.at(calls, completed) do
        {name, args} ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.tool_call_chunk(
              ToolName.encode(name),
              "domain-#{completed}",
              args
            ),
            DeterministicProvider.finish_chunk("tool_calls")
          ])

        nil ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk("native domain complete"),
            DeterministicProvider.finish_chunk("stop")
          ])
      end
    end)

    assert :ok =
             Worker.send_message(
               ctx.id,
               Keyword.get(opts, :message, "Use the native domain tools")
             )

    assert_receive {:domain_request, request, handler}, 5_000

    assert Enum.sort(Enum.map(request["tools"], &ToolName.decode(&1["function"]["name"]))) ==
             Enum.sort(
               ctx.harness.agent_config.id
               |> Synapsis.AgentConfigs.get()
               |> Map.fetch!(:tools)
             )

    runtime = runtime(ctx.id)
    runtime = Map.put(runtime, :descriptors, :sys.get_state(runtime.root).catalog.registry.tools)
    send(handler, :release_domain_response)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    runtime
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)
    %{root: state.root, store: state.store, run_id: state.run_id}
  end

  defp results(id),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        result = %ToolResult{} <- message.parts,
        do: result
      )

  defp intents(runtime) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    aggregate.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))
  end

  defp assert_public_replay(ctx, result) do
    requests = Agent.get(ctx.harness.counter, & &1.provider_requests)

    replay =
      for request <- requests,
          message <- request["messages"],
          message["role"] == "tool" and message["tool_call_id"] == result.tool_use_id,
          do: message["content"]

    assert [_ | _] = replay

    for content <- replay do
      assert content == result.content
      json = content |> String.split("\n", parts: 2) |> List.last()
      assert Jason.decode!(json) == result.projection["result"]["structured"]
    end
  end
end
