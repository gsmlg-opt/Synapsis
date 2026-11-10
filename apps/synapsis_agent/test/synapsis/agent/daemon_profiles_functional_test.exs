defmodule Synapsis.Agent.DaemonProfilesFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Daemon.{NativeSelection, Toolsets}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.Store

  @moduletag :tmp_dir
  @basic ~w(synapsis::read synapsis::ls synapsis::memory_source_search synapsis::todo_read
    synapsis::session_summarize synapsis::skill synapsis::agent_status
    synapsis::agent_discover synapsis::agent_inbox)
  @workspace @basic ++ ~w(synapsis::memory_save synapsis::memory_update synapsis::todo_write
    synapsis::write synapsis::edit apply_patch)
  @coding @workspace ++ ~w(exec_command write_stdin spawn_agent send_message followup_task
    interrupt_agent list_agents wait_agent)
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @read_pages Path.expand("../../fixtures/openclaw/488631c/read-pages.json", __DIR__)

  setup %{tmp_dir: root} do
    old_node = Application.fetch_env(:synapsis_agent, :filesystem_node)
    old_workspace = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    workspace = Path.join(root, "captured-workspace")
    File.mkdir_p!(workspace)
    Application.put_env(:synapsis_agent, :filesystem_node, @node)
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", workspace)

    on_exit(fn ->
      case old_node do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end

      if old_workspace,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", old_workspace),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    :ok
  end

  test "predefined profiles and aliases declare their exact native catalogs" do
    for profile <- ~w(assistant_basic read_only),
        do: assert(Toolsets.resolve(profile) == {:ok, @basic})

    for profile <- ~w(assistant_workspace reflect heartbeat),
        do: assert(Toolsets.resolve(profile) == {:ok, @workspace})

    for profile <- ~w(assistant_coding coding maintenance),
        do: assert(Toolsets.resolve(profile) == {:ok, @coding})

    dream = @basic ++ ~w(synapsis::memory_save synapsis::memory_update)
    assert Toolsets.resolve("assistant_dream") == {:ok, dream}
    assert Toolsets.resolve("assistant_dream_todo") == {:ok, dream ++ ["synapsis::todo_write"]}
  end

  test "named capture freezes profile provenance separately from the saved Agent selection",
       ctx do
    {saved, _fixture} = configured_agent(ctx.tmp_dir)

    assert {:ok, attrs} =
             NativeSelection.capture(%{
               assistant_name: saved.name,
               tool_profile: "assistant_basic"
             })

    expected = snapshot(saved, "assistant_basic", @basic)
    assert attrs.capability_snapshot == expected
    assert {:ok, ^expected} = NativeSelection.snapshot(attrs)
    assert Synapsis.AgentConfigs.get(saved.id).tools == ["synapsis::todo_read"]

    assert Synapsis.AgentConfigs.get(saved.id).config["deferred_tool_names"] == [
             "synapsis::todo_read"
           ]
  end

  test "basic Daemon Run reads one-based lines through the Worker and durable results", ctx do
    {daemon, _} = start_test_daemon()
    {saved, fixture} = configured_agent(ctx.tmp_dir)
    File.write!(Path.join(ctx.tmp_dir, "lines.txt"), "alpha\nbeta\ngamma\n")
    arguments = %{"path" => "lines.txt", "offset" => 2, "limit" => 1}
    install_provider(fixture, "synapsis::read", arguments)

    assert {:ok, queued} =
             Daemon.submit(daemon, "Read the second line", opts(saved, "assistant_basic"))

    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    verify_run(saved, queued, completed, "assistant_basic", @basic, "synapsis::read", arguments)
    assert [%ToolResult{} = result] = parts(completed.session_id, ToolResult)

    oracle =
      @read_pages
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("cases")
      |> Enum.find(&(&1["id"] == "one-based-slice"))
      |> Map.fetch!("result")

    assert result.content == oracle["text"]
  end

  test "coding Daemon Run executes its native command and persists the exact next result", ctx do
    {daemon, _} = start_test_daemon()
    {saved, fixture} = configured_agent(ctx.tmp_dir)

    arguments = %{
      "cmd" => "printf coding > coding-effect.txt",
      "login" => false,
      "yield_time_ms" => 1000
    }

    install_provider(fixture, "exec_command", arguments)

    assert {:ok, queued} =
             Daemon.submit(daemon, "Write the coding result", opts(saved, "assistant_coding"))

    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    verify_run(saved, queued, completed, "assistant_coding", @coding, "exec_command", arguments)
    assert File.read!(Path.join(ctx.tmp_dir, "coding-effect.txt")) == "coding"
  end

  test "stored named heartbeat reaches the same frozen native profile and real Worker", ctx do
    {daemon, _} = start_test_daemon()
    {saved, fixture} = configured_agent(ctx.tmp_dir)
    File.write!(Path.join(ctx.tmp_dir, "heartbeat.txt"), "heartbeat complete\n")
    arguments = %{"path" => "heartbeat.txt"}
    install_provider(fixture, "synapsis::read", arguments)

    assert {:ok, config} =
             Synapsis.Heartbeats.create(%{
               name: "named-heartbeat-#{Ecto.UUID.generate()}",
               agent_name: saved.name,
               enabled: true,
               prompt: "Read the heartbeat result",
               tool_profile: "assistant_workspace",
               schedule: "0 0 1 1 *"
             })

    on_exit(fn -> Synapsis.Heartbeats.delete(config) end)
    persisted = Synapsis.Heartbeats.get(config.id)
    assert {:ok, queued} = Synapsis.Agent.Heartbeat.Worker.execute(persisted, daemon)
    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    assert completed.kind == "heartbeat"
    assert completed.heartbeat_id == config.id

    verify_run(
      saved,
      queued,
      completed,
      "assistant_workspace",
      @workspace,
      "synapsis::read",
      arguments
    )

    assert [%ToolResult{content: "heartbeat complete\n"}] =
             parts(completed.session_id, ToolResult)
  end

  defp snapshot(saved, profile, names),
    do: %{
      "version" => 1,
      "selection_kind" => "native_profile",
      "agent_id" => saved.id,
      "agent_name" => saved.name,
      "tool_names" => names,
      "sources" => %{
        "agent" => %{"id" => saved.id, "name" => saved.name},
        "profile" => %{"name" => profile, "tool_contract_version" => 1, "tool_names" => names}
      }
    }

  defp opts(saved, profile), do: %{assistant_name: saved.name, tool_profile: profile}

  defp configured_agent(root) do
    fixture = Gaoxy.Test.open()
    name = "named-profile-#{Ecto.UUID.generate()}"

    assert {:ok, provider} =
             Synapsis.Providers.create(%{
               name: name,
               type: "openai_responses",
               api_key_encrypted: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: name,
               model: "gpt-4o",
               tools: ["synapsis::todo_read"],
               tool_contract_version: 1,
               permission_mode: "yolo",
               config: %{
                 "workspace_path" => root,
                 "deferred_tool_names" => ["synapsis::todo_read"]
               }
             })

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Providers.delete(provider.id)
    end)

    {saved, fixture}
  end

  defp verify_run(saved, queued, completed, profile, names, tool, arguments) do
    expected = snapshot(saved, profile, names)
    assert queued.capability_snapshot == expected
    assert completed.capability_snapshot == expected
    assert Runs.get(completed.id).capability_snapshot == expected
    assert_receive {:named_profile_request, 0, first}, 5000
    assert Enum.sort(Enum.map(first["tools"], &ToolName.decode(&1["name"]))) == Enum.sort(names)
    assert_receive {:named_profile_request, 1, following}, 5000

    assert [%ToolUse{tool: ^tool, input: ^arguments, tool_use_id: "profile-call"}] =
             parts(completed.session_id, ToolUse)

    assert [%ToolResult{is_error: false} = result] = parts(completed.session_id, ToolResult)

    assert %{
             "type" => "function_call_output",
             "call_id" => "profile-call",
             "output" => result.content
           } in following["input"]

    assert {:ok, meta} = Store.get_meta(completed.session_id)
    assert meta.config["daemon_run_id"] == completed.id
    assert meta.config["daemon_run_tool_contract_version"] == 1
    assert {:ok, turns} = Store.list_turns(completed.session_id)
    durable = for turn <- turns, part <- turn.parts, do: part

    assert Enum.any?(
             durable,
             &(&1[:type] == "tool_result" and &1[:tool_use_id] == result.tool_use_id and
                 &1[:content] == result.content and &1[:is_error] == false)
           )

    for part <- parts(completed.session_id, ToolUse) ++ [result] do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, resolved} = Synapsis.Agent.Resolver.resolve_configured(saved.name)
    assert {:ok, session} = Synapsis.Sessions.get(completed.session_id)
    overlay = NativeSelection.overlay(resolved, session)
    assert overlay.tools == names
    assert overlay.tool_contract_version == 1
    assert overlay.tool_selection_sources == expected["sources"]
    assert overlay.deferred_tool_names == []
    assert overlay.mcp_resource_source_ids == []
    assert Map.take(overlay, [:mcp_selection, :mcp_sources, :mcp_resource_sources]) == %{}
  end

  defp parts(id, module),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        part <- message.parts,
        part.__struct__ == module,
        do: part
      )

  defp install_provider(fixture, tool, arguments) do
    owner = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    Gaoxy.Test.stub(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(owner, {:named_profile_request, index, request})
      if index == 0, do: function_call(conn, tool, arguments), else: answer(conn)
    end)
  end

  defp function_call(conn, name, arguments) do
    encoded = Jason.encode!(arguments)

    item = %{
      "type" => "function_call",
      "id" => "profile-item",
      "call_id" => "profile-call",
      "name" => ToolName.encode(name),
      "arguments" => encoded
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "arguments", "")
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "profile-item",
        "delta" => encoded
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp answer(conn),
    do:
      sse(conn, [
        %{"type" => "response.output_text.delta", "delta" => "Profile complete"},
        completed([])
      ])

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
