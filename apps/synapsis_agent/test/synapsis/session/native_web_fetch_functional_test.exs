defmodule Synapsis.Session.NativeWebFetchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @name "web::fetch"

  for name <- [@name, "synapsis::web_search"] do
    test "a selected unconfigured #{name} lets normal chat complete", %{tmp_dir: root} do
      name = unquote(name)

      harness =
        SessionHarness.setup_session!(
          tmp_dir: root,
          install_provider?: false,
          session_config: %{"subagents" => false, "memory_context" => false}
        )

      on_exit(fn -> SessionHarness.cleanup!(harness) end)
      assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [name]})
      owner = self()

      Gaoxy.Test.expect(
        harness.provider.fixture,
        "POST",
        "/v1/responses",
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Formata.JSON.decode!(body)

          index =
            Agent.get_and_update(harness.counter, fn state ->
              {length(state.provider_requests),
               %{state | provider_requests: state.provider_requests ++ [request]}}
            end)

          chunks =
            case index do
              0 ->
                send(owner, {:unconfigured_web_request, request})

                [
                  DeterministicProvider.text_chunk("Hello"),
                  DeterministicProvider.finish_chunk("stop")
                ]

              1 ->
                [
                  DeterministicProvider.tool_call_chunk(
                    ToolName.encode(name),
                    "unavailable-web",
                    %{}
                  ),
                  DeterministicProvider.finish_chunk("tool_calls")
                ]

              2 ->
                send(owner, {:unavailable_web_result, request["input"]})

                [
                  DeterministicProvider.text_chunk("I can continue"),
                  DeterministicProvider.finish_chunk("stop")
                ]
            end

          DeterministicProvider.send_sse(conn, chunks)
        end,
        times: 3
      )

      SessionHarness.subscribe!(harness.session.id)
      SessionHarness.ensure_running!(harness.session.id)
      assert :ok = Worker.send_message(harness.session.id, "say hello")
      assert_receive {:unconfigured_web_request, request}, 5_000
      assert [%{"description" => description}] = request["tools"]
      assert description =~ "unavailable"
      assert_receive {:run_event, %{type: "session.completed"}}, 10_000
      SessionHarness.await_waiting!(harness.session.id)

      assert :ok = Worker.send_message(harness.session.id, "Try the web tool")
      assert_receive {:unavailable_web_result, items}, 10_000

      assert %{"type" => "function_call_output", "output" => explanation} =
               Enum.find(
                 items,
                 &(&1["call_id"] == "unavailable-web" and &1["type"] == "function_call_output")
               )

      assert explanation =~ "requires"
      assert explanation =~ if(name == @name, do: "web_allowed_hosts", else: "provider")
      assert_receive {:run_event, %{type: "session.completed"}}, 10_000
      assert Synapsis.AgentConfigs.get(harness.agent_config.id).tools == [name]
    end
  end

  test "selected original fetch reaches real HTTP, durable parts, next provider and restarted Worker",
       %{
         tmp_dir: root
       } do
    assert @name in Profiles.supported_names()
    assert [%{category: :web}] = Enum.filter(DisplayCatalog.list(), &(&1.name == @name))

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    resources = [
      {"native-fetch-1", "/article", 200, "The ordinary fetched article."},
      {"native-fetch-2", "/missing", 404, "The resource is missing."}
    ]

    expected =
      Enum.map(resources, fn {id, path, status, body} ->
        url = Gaoxy.Test.url(harness.provider.fixture, path)

        Gaoxy.Test.stub(harness.provider.fixture, "GET", path, fn conn ->
          Agent.update(harness.counter, &%{&1 | tool_executions: &1.tool_executions + 1})
          conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.resp(status, body)
        end)

        %{
          id: id,
          arguments: %{"url" => url},
          result: %{
            "status" => status,
            "body" => body,
            "url" => url,
            "content_type" =>
              if(status == 200, do: "text/plain", else: "text/plain; charset=utf-8")
          }
        }
      end)

    host = expected |> hd() |> get_in([:arguments, "url"]) |> URI.parse() |> Map.fetch!(:host)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
               config: Map.put(harness.agent_config.config, "web_allowed_hosts", [host])
             })

    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:fetch_request, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        runtime = :sys.get_state(data.runtime_pid, 1_000)
        catalog = :sys.get_state(runtime.root, 1_000).catalog
        send(owner, {:fetch_descriptor, catalog.registry.tools[@name], catalog.authority})
      end

      completed = Enum.count(request["input"], &(&1["type"] == "function_call_output"))

      chunks =
        case Enum.at(expected, completed) do
          nil ->
            [
              DeterministicProvider.text_chunk("Resources read"),
              DeterministicProvider.finish_chunk("stop")
            ]

          call ->
            [
              DeterministicProvider.tool_call_chunk(
                ToolName.encode(@name),
                call.id,
                call.arguments
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Read the two resources")
    assert_receive {:fetch_request, 0, first}, 5_000
    assert_receive {:fetch_descriptor, descriptor, authority}, 5_000
    assert descriptor.backend == Backend
    assert descriptor.backend_context.family == :service
    assert descriptor.codex_input_kind == :function
    assert descriptor.backend_context.context.web_transport == Synapsis.Web.Transport

    assert {:ok, original} =
             Codex.profile(:service_compat, descriptor.backend_context.context, authority,
               tools: [@name]
             )

    assert descriptor == original.registry.tools[@name]
    assert [%{"name" => encoded, "parameters" => schema}] = first["tools"]
    assert ToolName.decode(encoded) == @name
    assert schema == descriptor.schema
    assert_receive {:fetch_request, 1, following}, 10_000
    assert_receive {:fetch_request, 2, completed}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    [one, two] = expected
    assert_wire_results(following, [one])
    outputs = assert_wire_results(completed, expected)

    assert {:ok, turns} = Store.list_turns(harness.session.id)

    reloaded =
      Enum.map(Enum.with_index(turns), fn {turn, index} ->
        assert {:ok, loaded} = Store.get_turn(harness.session.id, index)
        assert loaded == turn
        loaded
      end)

    parts = for turn <- reloaded, part <- turn.parts, do: part

    assert [
             %{id: "native-fetch-1", name: @name, input: args1},
             %{id: "native-fetch-2", name: @name, input: args2}
           ] = Enum.filter(parts, &(&1[:type] == "tool_use"))

    assert args1 == one.arguments
    assert args2 == two.arguments

    assert [
             %{
               tool_use_id: "native-fetch-1",
               projection: projection1,
               content: content1,
               is_error: false
             },
             %{
               tool_use_id: "native-fetch-2",
               projection: projection2,
               content: content2,
               is_error: true
             }
           ] =
             Enum.filter(parts, &(&1[:type] == "tool_result"))

    assert [content1, content2] == outputs

    assert projection1 == %{
             "version" => 1,
             "result" =>
               content1
               |> Formata.JSON.decode!()
               |> Map.put("content", content1)
               |> Map.put("is_error", false)
           }

    assert %{"version" => 1, "result" => %{"is_error" => true}} = projection2

    host_parts =
      for message <- Synapsis.Message.list_by_session(harness.session.id),
          part <- message.parts,
          do: part

    assert [
             %ToolUse{tool_use_id: "native-fetch-1", tool: @name, input: ^args1},
             %ToolUse{tool_use_id: "native-fetch-2", tool: @name, input: ^args2}
           ] = Enum.filter(host_parts, &match?(%ToolUse{}, &1))

    assert [part1, part2] = Enum.filter(host_parts, &match?(%ToolResult{}, &1))

    for {part, projection} <- [{part1, projection1}, {part2, projection2}] do
      assert part.projection == projection
      assert {:ok, dump} = Synapsis.Part.dump(part)

      assert {:ok, ^part} =
               dump |> Formata.JSON.encode!() |> Formata.JSON.decode!() |> Synapsis.Part.load()
    end

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Recall the fetched resources")
    assert_receive {:fetch_request, 3, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert assert_wire_results(replay, expected) == outputs

    assert %{tool_executions: 2, provider_requests: [_, _, _, _]} =
             Agent.get(harness.counter, & &1)

    SessionHarness.await_waiting!(harness.session.id)
    agent = Synapsis.AgentConfigs.get(harness.agent_config.id)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(agent, %{
               config: Map.delete(agent.config, "web_allowed_hosts")
             })

    assert :ok = Worker.send_message(harness.session.id, "Continue with fetch unconfigured")
    assert_receive {:fetch_request, 4, unconfigured}, 10_000
    assert [%{"description" => description}] = unconfigured["tools"]
    assert description =~ "unavailable"
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert Agent.get(harness.counter, & &1.tool_executions) == 2
    assert Synapsis.AgentConfigs.get(agent.id).tools == [@name]
  end

  test "a delayed HTTP body times out and the same caller can fetch the next resource" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    Gaoxy.Test.stub(fixture, "GET", "/slow", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "Initial body")
      send(owner, :slow_resource_requested)
      Process.sleep(200)
      send(owner, :slow_resource_finished)
      conn
    end)

    Gaoxy.Test.stub(fixture, "GET", "/ready", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(200, "Ready resource")
    end)

    slow = Gaoxy.Test.url(fixture, "/slow")
    host = URI.parse(slow).host
    options = [allowed_hosts: [host], transport: Synapsis.Web.Transport, timeout: 100]
    started = System.monotonic_time(:millisecond)

    assert {:error, %Backplane.AgentRuntime.Error{class: class}} =
             Backplane.AgentRuntime.Codex.Web.fetch(slow, options)

    # Either the transport's absolute deadline or the HTTP client's receive
    # deadline can finish first. Both are explicit failures on the same owner.
    assert class in [:timeout, :transient_transport]
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive :slow_resource_requested, 1_000
    assert_receive :slow_resource_finished, 1_000

    ready = Gaoxy.Test.url(fixture, "/ready")

    assert {:ok, %{status: 200, body: "Ready resource", url: ^ready}} =
             Backplane.AgentRuntime.Codex.Web.fetch(ready, Keyword.put(options, :timeout, 1_000))
  end

  defp assert_wire_results(request, expected) do
    results =
      for message <- request["input"], message["type"] == "function_call_output", do: message

    assert Enum.map(results, & &1["call_id"]) == Enum.map(expected, & &1.id)

    Enum.zip(results, expected)
    |> Enum.map(fn {message, call} ->
      assert %{"type" => "function_call_output", "output" => output} = message

      if call.result["status"] == 200 do
        document = Formata.JSON.decode!(output)
        assert Map.take(document, ~w(status url content_type)) == Map.drop(call.result, ["body"])
        assert document["final_url"] == call.result["url"]
        assert document["text"] =~ call.result["body"]
        assert document["external_content"]["wrapped"] == true
      else
        assert output == "Tool execution failed"
      end

      output
    end)
  end
end
