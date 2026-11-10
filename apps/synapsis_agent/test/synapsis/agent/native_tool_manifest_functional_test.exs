defmodule Synapsis.Agent.NativeToolManifestFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.ContextBuilder
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.Worker

  @moduletag :tmp_dir
  @get "synapsis::workspace_memory_get"
  @memory "native-manifest-private-workspace-memory"
  @selected [@get, "clock::curr_time", "send_message"]
  @runtime_manifest """
  Selected tools:
  - clock::curr_time: Read the current UTC time.
  - send_message: Send a message to a native collaboration child agent.
  - synapsis::workspace_memory_get: Read a workspace memory document.
  """

  test "native display descriptions follow the exact selected static order" do
    agent = %{
      tool_contract_version: 1,
      tools: ["send_message", @get, "exec_command", "synapsis::swarm_message"]
    }

    assert ContextBuilder.build_skills_manifest(nil, agent) ==
             "Selected tools:\n" <>
               "- send_message: Send a message to a native collaboration child agent.\n" <>
               "- synapsis::workspace_memory_get: Read a workspace memory document.\n" <>
               "- exec_command: Run a command with streamed output and cancellation.\n" <>
               "- synapsis::swarm_message: Send a message through the Synapsis swarm."
  end

  test "explicit resolved empty definitions remain authoritative" do
    agent = %{tool_contract_version: 1, tools: @selected, resolved_tools: []}
    assert ContextBuilder.build_skills_manifest(nil, agent) == nil
  end

  test "explicit resolved definitions retain their order and bounded descriptions" do
    definitions = [
      %{name: "send_message", description: "Explicit resolved collaboration description"},
      %{name: @get, description: String.duplicate("m", 90)},
      %{name: "clock::curr_time", description: nil}
    ]

    agent = %{tool_contract_version: 1, tools: @selected, resolved_tools: definitions}

    assert ContextBuilder.build_skills_manifest(nil, agent) ==
             "Selected tools:\n" <>
               "- send_message: Explicit resolved collaboration description\n" <>
               "- synapsis::workspace_memory_get: #{String.duplicate("m", 79)}…\n" <>
               "- clock::curr_time: "

    assert agent.resolved_tools == definitions
  end

  test "selected UUID MCP metadata comes from the supplied immutable source snapshots" do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    first_name = "mcp::#{first_id}::lookup"
    second_name = "mcp::#{second_id}::lookup"
    parameters = %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}

    source = fn id, description, generation ->
      %{
        source_id: id,
        server_pid: self(),
        generation: generation,
        tools: [
          %{
            raw_name: "lookup",
            description: description,
            parameters: parameters,
            permission_level: :read
          },
          %{
            raw_name: "catalog_info",
            description: "Source catalog metadata",
            parameters: %{"type" => "object", "properties" => %{}},
            permission_level: :read
          }
        ]
      }
    end

    sources = %{
      first_id => source.(first_id, "First captured source lookup", 7),
      second_id => source.(second_id, "Second captured source lookup", 11)
    }

    agent = %{
      tool_contract_version: 1,
      tools: [second_name, "send_message", first_name],
      mcp_sources: sources,
      config: %{"manifest_marker" => "keep-original"}
    }

    before = :erlang.term_to_binary(agent)

    assert ContextBuilder.build_skills_manifest(nil, agent) ==
             "Selected tools:\n" <>
               "- #{second_name}: Second captured source lookup\n" <>
               "- send_message: Send a message to a native collaboration child agent.\n" <>
               "- #{first_name}: First captured source lookup"

    assert :erlang.term_to_binary(agent) == before
    assert agent.mcp_sources == sources
    assert agent.mcp_sources[first_id].tools |> hd() |> Map.fetch!(:parameters) == parameters
    assert agent.config == %{"manifest_marker" => "keep-original"}
  end

  test "root and child prompts keep the same selected descriptions with their memory option", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "MEMORY.md"), @memory)
    agent = %{tool_contract_version: 1, tools: @selected, skill_catalog: []}
    before = :erlang.term_to_binary(agent)
    opts = [workspace_path: root, agent_config: agent]
    root_prompt = ContextBuilder.build_system_prompt(:coding, opts)

    child_prompt =
      ContextBuilder.build_system_prompt(:coding, Keyword.put(opts, :memory_context, false))

    expected =
      "Selected tools:\n" <>
        "- synapsis::workspace_memory_get: Read a workspace memory document.\n" <>
        "- clock::curr_time: Read the current UTC time.\n" <>
        "- send_message: Send a message to a native collaboration child agent."

    assert manifest(root_prompt) == expected
    assert manifest(child_prompt) == expected
    assert root_prompt =~ @memory
    assert String.contains?(child_prompt, @memory) == false
    assert :erlang.term_to_binary(agent) == before
  end

  test "Worker provider receives selected native descriptions and canonical input schemas", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "MEMORY.md"), @memory)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => true}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: @selected})
    saved_before = Synapsis.AgentConfigs.get(harness.agent_config.id)
    assert saved_before.tools == @selected

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
      {_, data} = :sys.get_state(worker, 1_000)
      runtime = :sys.get_state(data.runtime_pid, 1_000)
      catalog = :sys.get_state(runtime.root, 1_000).catalog
      send(owner, {:manifest_request, request, runtime.context, catalog})
      text_response(conn)
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Describe the selected native tools")
    assert_receive {:manifest_request, request, context, catalog}, 5_000

    assert Enum.sort(Enum.map(request["tools"], &ToolName.decode(&1["name"]))) ==
             Enum.sort(@selected)

    for tool <- request["tools"] do
      name = ToolName.decode(tool["name"])
      assert tool["input_schema"] == catalog.registry.tools[name].schema
      assert tool["description"] == catalog.registry.tools[name].description
    end

    expected = String.trim_trailing(@runtime_manifest)
    assert manifest(context.system_prompt) == expected
    assert manifest(context.child_system_prompt) == expected
    assert manifest(system_text(request["system"])) == expected
    assert context.system_prompt =~ @memory
    assert String.contains?(context.child_system_prompt, @memory) == false
    assert context.agent.tool_contract_version == 1
    assert context.agent.tools == Enum.sort(@selected)
    assert context.agent.mcp_sources == %{}
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert Worker.snapshot(harness.session.id).status == :waiting
    assert Synapsis.AgentConfigs.get(harness.agent_config.id) == saved_before
  end

  defp manifest(prompt) do
    case Regex.run(~r/<available_skills>\n(.*?)\n<\/available_skills>/s, prompt) do
      [_, content] -> content
      nil -> nil
    end
  end

  defp system_text(text) when is_binary(text), do: text
  defp system_text(blocks) when is_list(blocks), do: Enum.map_join(blocks, & &1["text"])

  defp text_response(conn) do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Native manifest complete"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
      %{"type" => "message_stop"}
    ]

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end
end
