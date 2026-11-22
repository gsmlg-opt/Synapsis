defmodule Synapsis.Session.NativeResolverMCPFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.MCP.Server
  alias Synapsis.Part.{Image, ToolResult}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @raw_name "tools::read"
  @description "Read the selected native MCP source."
  @call_id "native-resolver-mcp-call"
  @arguments %{"label" => "retained"}
  @schema %{
    "type" => "object",
    "properties" => %{"label" => %{"type" => "string"}},
    "required" => ["label"],
    "additionalProperties" => false
  }

  test "saved UUID policy reaches native source schema, prompt, effect and durable Worker result",
       %{
         tmp_dir: root
       } do
    assert_native_source_turn(root, %{
      "content" => [%{"type" => "text", "text" => "source label retained"}],
      "structuredContent" => @arguments,
      "isError" => false
    })
  end

  @tag timeout: 90_000
  test "an MCP error arriving after sixty-five seconds reaches the next model request", %{
    tmp_dir: root
  } do
    assert_native_source_turn(
      root,
      %{
        "content" => [%{"type" => "text", "text" => "Source busy. Use an alternative."}],
        "isError" => true
      },
      66_500
    )
  end

  test "a near-limit image survives two MCP calls, Worker restart and fork", %{tmp_dir: root} do
    source_result = %{
      "content" => [%{"type" => "text", "text" => "source result"}],
      "isError" => false
    }

    {harness, name, _calls} = setup_source(root, source_result, 0)
    image = %Image{media_type: "image/png", data: Base.encode64(large_png())}
    image_url = "data:image/png;base64," <> image.data
    image_digest = :crypto.hash(:sha256, image_url)
    install_large_image_provider(harness, name)

    id = harness.session.id
    SessionHarness.subscribe!(id)
    SessionHarness.ensure_running!(id)
    assert :ok = Worker.send_message(id, "Read the image and search twice", [image])

    assert_receive {:large_image_request, 0, [^image_digest], []}, 10_000
    assert_receive {:native_resolver_source_call, _}, 5_000
    assert_receive {:large_image_request, 1, [^image_digest], [@call_id]}, 10_000
    assert_receive {:native_resolver_source_call, _}, 5_000
    second_call_id = @call_id <> "-2"
    assert_receive {:large_image_request, 2, [^image_digest], [@call_id, ^second_call_id]}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert [%{id: image_message_id, parts: [_, ^image]} | _] =
             Synapsis.Sessions.get_messages(id)

    assert {:ok, %{root: %{run_id: run_id, namespace: namespace}}} =
             Synapsis.Runtime.Store.get_projection(id)

    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(namespace, run_id)
    assert :erlang.external_size(aggregate) < byte_size(image.data)

    SessionHarness.await_waiting!(id)
    assert :ok = DynamicSupervisor.stop_session(id)
    SessionHarness.ensure_running!(id)
    assert :ok = Worker.send_message(id, "Read the same image after restarting")
    assert_receive {:large_image_request, 3, [^image_digest], [@call_id, ^second_call_id]}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert {:ok, branch} = Synapsis.Sessions.fork(id, at_message: image_message_id)
    on_exit(fn -> Synapsis.Sessions.delete(branch.id) end)
    SessionHarness.subscribe!(branch.id)
    SessionHarness.ensure_running!(branch.id)
    assert :ok = Worker.send_message(branch.id, "Read the image in this fork")
    assert_receive {:large_image_request, 4, [^image_digest], []}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
  end

  defp setup_source(root, source_result, delay_ms) do
    owner = self()
    calls = start_supervised!({Agent, fn -> [] end})

    fixture =
      Gaoxy.Test.open(limits: %{idle_timeout: 80_000}, http_limits: %{request_timeout: 80_000})

    install_source(fixture, calls, owner, source_result, delay_ms)

    {:ok, source} =
      Synapsis.MCPConfigs.create(%{
        name: "resolver-mcp-#{System.unique_integer([:positive, :monotonic])}",
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

    {harness, name, calls}
  end

  defp assert_native_source_turn(root, source_result, delay_ms \\ 0) do
    {harness, name, calls} = setup_source(root, source_result, delay_ms)
    assert {:ok, agent_before} = ConfigStore.get(:agent, harness.agent_config.id)
    install_provider(harness, name, self())
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok = Worker.send_message(harness.session.id, "Read the selected source label")
    assert_receive {:native_resolver_provider, 0, first, _handler}, 5_000
    assert [%{"type" => "function"} = function] = first["tools"]
    assert function["name"] == ToolName.encode(name)
    assert function["description"] == @description
    assert function["parameters"] == @schema

    prompt = first["instructions"]

    assert prompt =~ "Selected tools:\n- #{name}: #{@description}"
    assert_receive {:native_resolver_source_call, source_call}, 5_000
    assert source_call == %{"name" => @raw_name, "arguments" => @arguments}
    assert_receive {:native_resolver_provider, 1, following, handler}, delay_ms + 5_000

    assert [%{"type" => "function_call_output", "call_id" => @call_id} = wire_result] =
             Enum.filter(following["input"], &(&1["type"] == "function_call_output"))

    send(handler, :complete_native_resolver_mcp)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    is_error = source_result["isError"]

    assert [%ToolResult{tool_use_id: @call_id, is_error: ^is_error} = result] =
             for(
               message <- Synapsis.Sessions.get_messages(harness.session.id),
               part = %ToolResult{} <- message.parts,
               do: part
             )

    assert [%{"type" => "text", "text" => feedback}] = source_result["content"]
    assert wire_result["output"] == feedback
    assert result.content == feedback
    assert result.projection["result"]["content"] == source_result["content"]

    assert result.projection["result"]["structured"] == source_result["structuredContent"]
    assert Agent.get(calls, & &1) == [source_call]
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 2
    assert {:ok, turns} = Store.list_turns(harness.session.id)
    durable_parts = for turn <- turns, part <- turn.parts, do: part

    assert Enum.filter(durable_parts, &(&1[:type] == "tool_result")) == [
             %{
               type: "tool_result",
               tool_use_id: @call_id,
               content: result.content,
               is_error: is_error,
               projection: result.projection
             }
           ]

    assert {:ok, ^agent_before} = ConfigStore.get(:agent, harness.agent_config.id)
  end

  defp install_source(fixture, calls, owner, tool_result, delay_ms) do
    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "native-resolver-fixture", "version" => "1"}
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
            params = request["params"]
            Agent.update(calls, &(&1 ++ [params]))
            send(owner, {:native_resolver_source_call, params})

            Process.sleep(delay_ms)
            tool_result

          _notification ->
            %{}
        end

      if Map.has_key?(request, "id") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Formata.JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))
  end

  defp install_provider(harness, name, owner) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:native_resolver_provider, index, request, self()})

      case index do
        0 ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.tool_call_chunk(ToolName.encode(name), @call_id, @arguments),
            DeterministicProvider.finish_chunk("tool_calls")
          ])

        1 ->
          {:released, conn} =
            AbortableHTTP.await(conn, :complete_native_resolver_mcp, 10_000, owner)

          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk("Native source turn complete"),
            DeterministicProvider.finish_chunk("stop")
          ])
      end
    end)
  end

  defp install_large_image_provider(harness, name) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: [true | state.provider_requests]}}
        end)

      images =
        for %{"content" => blocks} <- request["input"],
            is_list(blocks),
            %{"type" => "input_image", "image_url" => url} <- blocks,
            do: :crypto.hash(:sha256, url)

      call_ids =
        for %{"type" => "function_call_output", "call_id" => id} <- request["input"], do: id

      send(owner, {:large_image_request, index, images, call_ids})

      if index in [0, 1] do
        call_id = if index == 0, do: @call_id, else: @call_id <> "-2"

        DeterministicProvider.send_sse(conn, [
          DeterministicProvider.tool_call_chunk(ToolName.encode(name), call_id, @arguments),
          DeterministicProvider.finish_chunk("tool_calls")
        ])
      else
        DeterministicProvider.send_sse(conn, [
          DeterministicProvider.text_chunk("Read the image"),
          DeterministicProvider.finish_chunk("stop")
        ])
      end
    end)
  end

  defp large_png do
    width = 1280
    height = 1360
    row_size = width * 3
    pixels = :crypto.strong_rand_bytes(row_size * height)
    rows = for <<row::binary-size(row_size) <- pixels>>, into: <<>>, do: <<0, row::binary>>

    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      png_chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>),
      png_chunk("IDAT", :zlib.compress(rows)),
      png_chunk("IEND", <<>>)
    ])
  end

  defp png_chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
end
