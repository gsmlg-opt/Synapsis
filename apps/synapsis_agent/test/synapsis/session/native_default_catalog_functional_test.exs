defmodule Synapsis.Session.NativeDefaultCatalogFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.Resolver
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{Discovery, Filesystem, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.{AgentConfigs, Config}

  @moduletag :tmp_dir
  @names ~w(
    synapsis::read synapsis::write synapsis::edit synapsis::ls
    apply_patch exec_command write_stdin
    synapsis::todo_read synapsis::todo_write
    synapsis::enter_plan_mode synapsis::exit_plan_mode
    spawn_agent send_message followup_task interrupt_agent list_agents wait_agent
    synapsis::skill synapsis::ask_user clock::sleep
    synapsis::memory_save synapsis::memory_source_search synapsis::memory_update
    synapsis::session_summarize
  )
  @coding ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls apply_patch exec_command write_stdin)
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @read_pages Path.expand("../../fixtures/openclaw/488631c/read-pages.json", __DIR__)

  setup %{tmp_dir: root} do
    previous_node = Application.fetch_env(:synapsis_agent, :filesystem_node)
    previous_workspace = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    workspace = Path.join(root, "captured-workspace")
    File.mkdir_p!(workspace)
    Application.put_env(:synapsis_agent, :filesystem_node, @node)
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", workspace)

    on_exit(fn ->
      case previous_node do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end

      if previous_workspace,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous_workspace),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    :ok
  end

  test "future main defaults and fresh Resolver fallback declare the complete native selection" do
    attrs = AgentConfigs.default_attrs("main")
    assert attrs.tools == @names
    assert attrs.tool_contract_version == 1

    # A unique missing name follows the real fallback without changing saved main.
    agent = Resolver.resolve(unique_name("missing-default"))
    assert agent.name == "main"
    assert agent.tools == @names
    assert agent.tool_contract_version == 1
    assert agent.deferred_tool_names == []

    assert {:ok, @names} = Profiles.selection(%{agent: agent, session: %{config: %{}}})
    assert {:ok, plan} = Discovery.plan(agent, @names)
    assert plan.selected == @names
    assert plan.runtime == @names
    assert plan.initial == @names
    assert plan.deferred == []
  end

  test "coding defaults retain their native declaration through Config.save_agent" do
    defaults = Config.defaults()["agents"]["main"]
    assert defaults["tools"] == @coding
    assert defaults["toolContractVersion"] == 1

    name = unique_name("saved-native-default")
    assert :ok = Config.save_agent(name, defaults)
    saved = AgentConfigs.get_by_name(name)
    on_exit(fn -> AgentConfigs.delete(saved) end)

    assert saved.tools == @coding
    assert saved.tool_contract_version == 1
    assert {:ok, raw} = Synapsis.Config.Store.get(:agent, saved.id)
    assert raw["tools"] == @coding
    assert raw["tool_contract_version"] == 1

    resolved = Resolver.resolve(name)
    assert resolved.tools == @coding
    assert resolved.tool_contract_version == 1

    assert {:ok, @coding} =
             Profiles.selection(%{agent: resolved, session: %{config: %{}}})
  end

  test "a newly persisted default assembles the full Worker catalog and reads through Concord", %{
    tmp_dir: root
  } do
    harness = default_harness(root)
    File.write!(Path.join(root, "lines.txt"), "alpha\nbeta\ngamma\n")
    owner = self()
    arguments = %{"path" => "lines.txt", "offset" => 2, "limit" => 1}

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:default_catalog_request, index, request})

      if index == 0 do
        send(owner, {:default_catalog_runtime, runtime(harness.session.id)})
        function_call(conn, "default-read", "synapsis::read", arguments)
      else
        answer(conn)
      end
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(harness.session.id, "Read line two using the default catalog")

    assert_receive {:default_catalog_request, 0, first}, 5_000
    assert_receive {:default_catalog_runtime, runtime}, 5_000
    assert first["model"] == "gpt-4o"
    assert Enum.sort(Map.keys(runtime.catalog.registry.tools)) == Enum.sort(@names)

    assert Enum.sort(Enum.map(first["tools"], &ToolName.decode(&1["name"]))) ==
             Enum.sort(@names)

    assert runtime.catalog.registry.tools["synapsis::read"].backend == Filesystem
    assert runtime.catalog.registry.tools["apply_patch"].backend == Backend
    assert runtime.catalog.registry.tools["apply_patch"].codex_input_kind == :custom
    assert runtime.catalog.registry.tools["exec_command"].backend == Backend
    assert runtime.catalog.registry.tools["spawn_agent"].backend == Backend

    assert_receive {:default_catalog_request, 1, second}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    parts =
      for message <- Synapsis.Sessions.get_messages(harness.session.id),
          part <- message.parts,
          match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
          do: part

    assert [%ToolUse{} = use, %ToolResult{} = result] = parts
    assert use.tool_use_id == "default-read"
    assert use.tool == "synapsis::read"
    assert use.input == arguments

    captured =
      @read_pages
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("cases")
      |> Enum.find(&(&1["id"] == "one-based-slice"))
      |> Map.fetch!("result")

    expected = %{
      "content" => [%{"type" => "text", "text" => captured["text"]}],
      "details" => captured["details"],
      "is_error" => false
    }

    assert result.tool_use_id == "default-read"
    assert result.is_error == false
    assert result.content == captured["text"]
    assert result.projection == %{"version" => 1, "result" => expected}

    assert Enum.any?(
             second["input"],
             &(&1["type"] == "function_call" and &1["call_id"] == use.tool_use_id and
                 ToolName.decode(&1["name"]) == use.tool and
                 Jason.decode!(&1["arguments"]) == arguments)
           )

    assert %{
             "type" => "function_call_output",
             "call_id" => "default-read",
             "output" => captured["text"]
           } in second["input"]

    assert {:ok, turns} = Store.list_turns(harness.session.id)
    durable = for turn <- turns, part <- turn.parts, do: part

    assert Enum.any?(
             durable,
             &(&1[:type] == "tool_use" and &1[:id] == use.tool_use_id and
                 &1[:name] == use.tool and &1[:input] == arguments)
           )

    assert Enum.any?(
             durable,
             &(&1[:type] == "tool_result" and &1[:tool_use_id] == result.tool_use_id and
                 &1[:projection] == result.projection and &1[:content] == captured["text"] and
                 &1[:is_error] == false)
           )

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, aggregate} =
             Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

    operations =
      for {_, intent} <- aggregate.run.execution_intents,
          intent.type == :tool,
          do: intent.operation

    assert [operation] = operations
    assert operation.tool_name == "synapsis::read"
    assert operation.arguments == arguments
  end

  defp default_harness(root) do
    assert {:ok, counter} = Agent.start_link(fn -> %{provider_requests: []} end)
    provider = DeterministicProvider.start!(install?: false)

    assert {:ok, provider_config} =
             Synapsis.Providers.create(%{
               name: provider.name,
               type: "openai_responses",
               base_url: provider.base_url,
               api_key_encrypted: "test-key"
             })

    attrs =
      AgentConfigs.default_attrs("main")
      |> Map.merge(%{
        name: unique_name("default-worker"),
        is_default: false,
        provider: provider.name,
        model: "gpt-4o",
        config: %{"workspace_path" => root}
      })

    assert {:ok, agent_config} = AgentConfigs.create(attrs)
    assert agent_config.tools == @names
    assert agent_config.tool_contract_version == 1

    assert {:ok, session} =
             Synapsis.Sessions.create(agent_config.name, %{
               agent: agent_config.name,
               provider: provider.name,
               model: "gpt-4o",
               config: %{"subagents" => true, "memory_context" => false}
             })

    harness = %{
      session: session,
      agent_config: agent_config,
      agent_name: agent_config.name,
      provider: provider,
      tool_name: nil,
      counter: counter,
      tmp_dir: root
    }

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      Synapsis.Providers.delete(provider_config.id)
    end)

    # Normal all-allow setup is a prerequisite; no permission behavior is tested.
    permission = Store.get_value(session.id, "permission")

    assert :ok =
             Store.put_value(session.id, "permission", %{
               permission
               | tool_contract_version: 1,
                 allow_read: :allow,
                 allow_write: :allow,
                 allow_execute: :allow,
                 allow_destructive: :allow
             })

    harness
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    state = :sys.get_state(data.runtime_pid, 1_000)

    %{
      catalog: :sys.get_state(state.root, 1_000).catalog,
      run_id: state.run_id,
      store: state.store
    }
  end

  defp function_call(conn, id, name, arguments) do
    encoded = Jason.encode!(arguments)

    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
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
        "item_id" => item["id"],
        "delta" => encoded
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp answer(conn),
    do:
      sse(conn, [
        %{"type" => "response.output_text.delta", "delta" => "Default catalog complete"},
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
