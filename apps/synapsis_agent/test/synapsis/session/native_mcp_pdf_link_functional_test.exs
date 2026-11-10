defmodule Synapsis.Session.NativeMCPPDFLinkFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.MCP.Server
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @raw_name "reports::read"
  @description "Read the selected report with its preview and PDF link."
  @call_id "native-mcp-pdf-link-call"
  @arguments %{"report" => "annual"}
  @schema %{
    "type" => "object",
    "properties" => %{"report" => %{"type" => "string"}},
    "required" => ["report"],
    "additionalProperties" => false
  }
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
  @pdf_url "https://example.test/reports/annual.pdf"
  @pdf_name "Annual report.pdf"
  @prompt "Read the selected annual report"
  @recall "Recall the completed annual report"
  @completion "Report preview and PDF link received"
  @legacy_text "Before the report preview\nAfter the report PDF"
  @structured %{"report" => "annual", "pages" => 2}
  @metadata %{"fixture" => "native-mcp-pdf-link"}

  # These are the raw MCP tools/call blocks, with no canonical result injection.
  # The HTTPS URI is reference data; neither fixture nor test fetches the PDF.
  @raw_blocks [
    %{"type" => "text", "text" => "Before the report preview"},
    %{"type" => "image", "mimeType" => "image/png", "data" => @png},
    %{
      "type" => "resource_link",
      "uri" => @pdf_url,
      "name" => @pdf_name,
      "mimeType" => "application/pdf"
    },
    %{"type" => "text", "text" => "After the report PDF"}
  ]
  @raw_result %{
    "content" => @raw_blocks,
    "structuredContent" => @structured,
    "_meta" => @metadata,
    "isError" => false
  }

  # Independent expected public projection from MCP.completed/1 and ResultProjection.
  @projection %{
    "version" => 1,
    "result" => %{
      "content" => @raw_blocks,
      "structured" => @structured,
      "metadata" => %{"mcp" => %{"_meta" => @metadata}},
      "is_error" => false
    }
  }

  # Independent official Anthropic codec expectation; retained sidecars are absent.
  @wire_blocks [
    %{"type" => "text", "text" => "Before the report preview"},
    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => "image/png", "data" => @png}
    },
    %{
      "type" => "document",
      "source" => %{"type" => "url", "url" => @pdf_url},
      "title" => @pdf_name
    },
    %{"type" => "text", "text" => "After the report PDF"}
  ]

  test "saved MCP UUID emits ordered text, PNG and PDF link through Worker and durable new-Worker replay",
       %{tmp_dir: root} do
    owner = self()
    source_requests = start_supervised!({Agent, fn -> [] end})
    fixture = Gaoxy.Test.open()
    install_source(fixture, source_requests)

    assert {:ok, source} =
             Synapsis.MCPConfigs.create(%{
               name: "pdf-link-mcp-#{System.unique_integer([:positive, :monotonic])}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
    source_pid = start_supervised!(Supervisor.child_spec({Server, source}, restart: :temporary))
    assert :ok = Server.await_ready(source_pid)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    name = "mcp::#{source.id}::#{@raw_name}"

    policy = %{
      "default" => "selected",
      "sources" => %{source.id => %{"mode" => "selected", "tools" => [@raw_name]}}
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [name],
               config: Map.put(harness.agent_config.config, "mcp_selection", policy)
             })

    assert {:ok, saved_agent} = ConfigStore.get(:agent, harness.agent_config.id)
    assert saved_agent["tools"] == [name]
    assert Jason.decode!(saved_agent["config"])["mcp_selection"] == policy

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "fixture"
             })

    install_provider(harness, name, owner)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, @prompt)
    assert_receive {:mcp_pdf_provider, 0, first}, 5_000
    assert_catalog(first, name)
    assert first["messages"] == [text_message("user", @prompt)]
    assert_receive {:mcp_pdf_provider, 1, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_catalog(following, name)
    assert following["messages"] == expected_history(name)
    assert_wire_media(following)

    expected_use = %ToolUse{tool_use_id: @call_id, tool: name, input: @arguments}

    expected_result = %ToolResult{
      tool_use_id: @call_id,
      content: @legacy_text,
      is_error: false,
      projection: @projection
    }

    expected_parts = [
      %Text{content: @prompt},
      expected_use,
      expected_result,
      %Text{content: @completion}
    ]

    actual_parts = parts(harness.session.id)
    assert actual_parts == expected_parts
    [_, actual_use, actual_result, _] = actual_parts
    assert_projection_and_round_trip(actual_use, actual_result)
    assert_durable(harness.session.id, name, false)
    assert_source_calls(source_requests)

    requests = Agent.get(source_requests, & &1)

    assert [%{"params" => %{"protocolVersion" => "2025-06-18"}}] =
             Enum.filter(requests, &(&1["method"] == "initialize"))

    assert Enum.any?(requests, &(&1["method"] == "notifications/initialized"))
    assert Enum.any?(requests, &(&1["method"] == "tools/list"))

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute old_worker == new_worker

    assert :ok = Worker.send_message(harness.session.id, @recall)
    assert_receive {:mcp_pdf_provider, 2, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_catalog(replay, name)

    assert replay["messages"] ==
             expected_history(name) ++
               [text_message("assistant", @completion), text_message("user", @recall)]

    assert_wire_media(replay)

    reloaded_parts = parts(harness.session.id)

    assert reloaded_parts ==
             expected_parts ++ [%Text{content: @recall}, %Text{content: @completion}]

    [_, reloaded_use, reloaded_result, _, _, _] = reloaded_parts
    assert_projection_and_round_trip(reloaded_use, reloaded_result)
    assert_durable(harness.session.id, name, true)
    assert_source_calls(source_requests)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 3
    assert {:ok, ^saved_agent} = ConfigStore.get(:agent, harness.agent_config.id)
  end

  defp install_source(fixture, requests) do
    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(requests, &(&1 ++ [request]))

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "native-mcp-pdf-link", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => @raw_name,
                  "description" => @description,
                  "annotations" => %{"readOnlyHint" => true},
                  "inputSchema" => @schema
                }
              ]
            }

          "tools/call" ->
            @raw_result

          "notifications/initialized" ->
            %{}
        end

      if Map.has_key?(request, "id") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))
  end

  defp install_provider(harness, name, owner) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:mcp_pdf_provider, index, request})

      {block, delta, stop} =
        if index == 0 do
          {%{
             "type" => "tool_use",
             "id" => @call_id,
             "name" => ToolName.encode(name),
             "input" => %{}
           }, %{"type" => "input_json_delta", "partial_json" => Jason.encode!(@arguments)},
           "tool_use"}
        else
          {%{"type" => "text", "text" => ""}, %{"type" => "text_delta", "text" => @completion},
           "end_turn"}
        end

      events = [
        %{"type" => "content_block_start", "index" => 0, "content_block" => block},
        %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => stop}},
        %{"type" => "message_stop"}
      ]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
    end)
  end

  defp assert_catalog(request, name) do
    assert request["tools"] == [
             %{
               "name" => ToolName.encode(name),
               "description" => @description,
               "input_schema" => @schema
             }
           ]
  end

  defp expected_history(name) do
    [
      text_message("user", @prompt),
      %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => @call_id,
            "name" => ToolName.encode(name),
            "input" => @arguments
          }
        ]
      },
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => @call_id,
            "is_error" => false,
            "content" => @wire_blocks
          }
        ]
      }
    ]
  end

  defp text_message(role, text),
    do: %{"role" => role, "content" => [%{"type" => "text", "text" => text}]}

  defp assert_wire_media(request) do
    results =
      for message <- request["messages"],
          block <- message["content"],
          block["type"] == "tool_result",
          do: block

    assert [%{"tool_use_id" => @call_id, "content" => [_, image, document, _]}] = results
    assert Base.decode64!(image["source"]["data"]) == Base.decode64!(@png)
    assert document["source"]["url"] == @pdf_url
    assert document["title"] == @pdf_name
  end

  defp assert_projection_and_round_trip(use, result) do
    assert result.projection == @projection
    retained = result.projection["result"]

    assert %{
             "content" => retained["content"],
             "structuredContent" => retained["structured"],
             "_meta" => retained["metadata"]["mcp"]["_meta"],
             "isError" => retained["is_error"]
           } == @raw_result

    for part <- [use, result] do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end
  end

  defp assert_source_calls(requests) do
    calls =
      for request <- Agent.get(requests, & &1),
          request["method"] == "tools/call",
          do: request["params"]

    assert calls == [%{"name" => @raw_name, "arguments" => @arguments}]
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_durable(id, name, replay?) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    expected = [
      %{type: "text", text: @prompt},
      %{type: "tool_use", id: @call_id, name: name, input: @arguments, status: "pending"},
      %{
        type: "tool_result",
        tool_use_id: @call_id,
        content: @legacy_text,
        is_error: false,
        projection: @projection
      },
      %{type: "text", text: @completion}
    ]

    expected =
      if replay?,
        do:
          expected ++
            [%{type: "text", text: @recall}, %{type: "text", text: @completion}],
        else: expected

    assert for(turn <- turns, part <- turn.parts, do: part) == expected
  end
end
