defmodule Synapsis.Session.NativeWebFetchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @name "web::fetch"

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
            "content_type" => "text/plain; charset=utf-8",
            "content" => body,
            "is_error" => false
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

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

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

      completed = Enum.count(request["messages"], &(&1["role"] == "tool"))

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
    assert [%{"function" => %{"name" => encoded, "parameters" => schema}}] = first["tools"]
    assert ToolName.decode(encoded) == @name
    assert schema == descriptor.schema
    assert_receive {:fetch_request, 1, following}, 10_000
    assert_receive {:fetch_request, 2, completed}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    [one, two] = expected
    assert_wire_results(following, [one])
    assert_wire_results(completed, expected)

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
               is_error: false
             }
           ] =
             Enum.filter(parts, &(&1[:type] == "tool_result"))

    assert projection1 == %{"version" => 1, "result" => one.result}
    assert projection2 == %{"version" => 1, "result" => two.result}
    assert content1 == one.result["body"]
    assert content2 == two.result["body"]

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
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Recall the fetched resources")
    assert_receive {:fetch_request, 3, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_wire_results(replay, expected)

    assert %{tool_executions: 2, provider_requests: [_, _, _, _]} =
             Agent.get(harness.counter, & &1)
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
    results = for message <- request["messages"], message["role"] == "tool", do: message
    assert Enum.map(results, & &1["tool_call_id"]) == Enum.map(expected, & &1.id)

    Enum.zip(results, expected)
    |> Enum.each(fn {message, call} ->
      assert message == %{
               "role" => "tool",
               "tool_call_id" => call.id,
               "content" => call.result["body"]
             }
    end)
  end
end
