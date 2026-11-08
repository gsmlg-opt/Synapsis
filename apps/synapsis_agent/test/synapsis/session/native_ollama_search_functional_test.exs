defmodule Synapsis.Session.NativeOllamaSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"

  test "selected Ollama preserves raw calls and completed durable history across ordinary Worker replacement",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    install_search(harness)

    config =
      Map.put(harness.agent_config.config, "web_search", %{
        "provider" => "ollama",
        "base_url" => Gaoxy.Test.url(harness.provider.fixture, "/ordinary/v1/V1///"),
        "cache_ttl_ms" => 60_000,
        "count" => 3
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})

    args = %{
      "query" => ~s( 雪🙂 "语言模型" site:example.org -site:archive.example lang:zh after:2026-01-01 ),
      "count" => 2
    }

    calls = [{"ollama-first", @name, args}, {"ollama-cached", @name, args}]
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search Ollama")
    requests = for index <- 0..2, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    assert Map.keys(descriptors) == [@name]
    assert descriptors[@name].backend == Search
    assert descriptors[@name].backend_context.config.provider == "ollama"
    assert descriptors[@name].backend_context.config.timeout_ms == 15_000

    assert descriptors[@name].backend_context.config.base_url ==
             Gaoxy.Test.url(harness.provider.fixture, "/ordinary/v1")

    schema = descriptors[@name].schema

    for group <- reference()["groups"] do
      assert descriptors[@name].description == group["descriptor"]["description"], group["id"]
      assert schema == group["descriptor"]["parameters"], group["id"]
    end

    assert hd(requests)["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => ToolName.encode(@name),
                 "description" => descriptors[@name].description,
                 "parameters" => schema
               }
             }
           ]

    assert descriptors[@name].description ==
             "Search the web using Ollama's web search API. Returns titles, URLs, and snippets from the configured Ollama host."

    assert schema == %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "description" => "Search query string."},
               "count" => %{
                 "type" => "integer",
                 "description" => "Number of results to return (1-10).",
                 "minimum" => 1,
                 "maximum" => 10
               }
             },
             "required" => ["query"],
             "additionalProperties" => false
           }

    parts = parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))

    assert uses ==
             Enum.map(calls, fn {id, name, input} ->
               %ToolUse{tool_use_id: id, tool: name, input: input, status: :pending}
             end)

    assert Enum.map(results, & &1.tool_use_id) == ["ollama-first", "ollama-cached"]
    assert Enum.all?(results, &(&1.is_error == false))
    [first, cached] = Enum.map(results, &Jason.decode!(&1.content))

    assert Map.delete(first, "tookMs") == %{
             "provider" => "ollama",
             "query" => args["query"],
             "kind" => "results",
             "count" => 2,
             "results" => rows()
           }

    assert is_integer(first["tookMs"])
    assert first["tookMs"] >= 0
    assert cached == Map.put(first, "cached", true)

    for result <- results do
      public = Jason.decode!(result.content)

      assert result.projection == %{
               "version" => 1,
               "result" => Map.merge(public, %{"content" => result.content, "is_error" => false})
             }
    end

    for {req, count} <- Enum.with_index(requests),
        do: assert_wire(req, Enum.take(calls, count), Enum.take(results, count))

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)

      expected_dump =
        case part do
          %ToolUse{} ->
            %{
              "type" => "tool_use",
              "tool" => part.tool,
              "tool_use_id" => part.tool_use_id,
              "input" => part.input,
              "status" => "pending"
            }

          %ToolResult{} ->
            %{
              "type" => "tool_result",
              "tool_use_id" => part.tool_use_id,
              "content" => part.content,
              "projection" => part.projection,
              "is_error" => false
            }
        end

      assert dump == expected_dump

      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness, args)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    {_, worker_data} = :sys.get_state(old_worker)
    runtime = :sys.get_state(worker_data.runtime_pid)
    assert is_pid(initial_root)
    refute Process.alive?(initial_root)
    assert runtime.root == nil
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5000
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute old_worker == new_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall searches")
    replay = request(3)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             parts ++ [%Text{content: "Recall searches"}, %Text{content: "Searches complete"}]

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness, args)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 4
  end

  defp rows do
    [
      %{
        "title" => "First source 雪",
        "url" => "https://www.source.example/ordinary%20path?q=hello%20world#section",
        "snippet" => "First passage 雪",
        "siteName" => "www.source.example"
      },
      %{
        "title" => "Second source",
        "url" => "http://news.example/story",
        "snippet" => "Second passage 🙂",
        "siteName" => "news.example"
      }
    ]
  end

  defp reference do
    Path.expand("../../fixtures/openclaw/488631c/ollama-search.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp install_search(harness) do
    payload = %{
      "results" => [
        %{
          "title" => " First source 雪 ",
          "url" => " https://WWW.SOURCE.EXAMPLE:443/ordinary path?q=hello world#section ",
          "content" => " First passage 雪 "
        },
        %{
          "title" => " Second source ",
          "url" => "http://NEWS.EXAMPLE:80/story",
          "content" => " Second passage 🙂 "
        }
      ]
    }

    Gaoxy.Test.stub(
      harness.provider.fixture,
      "POST",
      "/ordinary/v1/api/experimental/web_search",
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        Agent.update(
          harness.counter,
          &%{
            &1
            | search_requests: &1.search_requests ++ [{conn.request_path, Jason.decode!(body)}]
          }
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(payload))
      end
    )
  end

  defp assert_effect(harness, args) do
    assert Agent.get(harness.counter, & &1.search_requests) == [
             {"/ordinary/v1/api/experimental/web_search",
              %{"query" => String.trim(args["query"]), "max_results" => 2}}
           ]
  end

  defp install_provider(harness, calls) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [req]}}
        end)

      send(owner, {:search_request, index, req})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker)
        runtime = :sys.get_state(data.runtime_pid)

        send(
          owner,
          {:search_descriptors, :sys.get_state(runtime.root).catalog.registry.tools, runtime.root}
        )
      end

      completed = Enum.count(req["messages"], &(&1["role"] == "tool"))

      chunks =
        case Enum.at(calls, completed) do
          {id, name, args} ->
            [
              DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          nil ->
            [
              DeterministicProvider.text_chunk("Searches complete"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp request(index) do
    assert_receive {:search_request, ^index, request}, 15_000
    request
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_wire(req, calls, results) do
    uses = for message <- req["messages"], call <- List.wrap(message["tool_calls"]), do: call

    assert Enum.map(uses, fn call ->
             update_in(call, ["function", "arguments"], &Jason.decode!/1)
           end) ==
             Enum.map(calls, fn {id, name, input} ->
               %{
                 "id" => id,
                 "type" => "function",
                 "function" => %{"name" => ToolName.encode(name), "arguments" => input}
               }
             end)

    actual = for message <- req["messages"], message["role"] == "tool", do: message

    assert actual ==
             Enum.map(
               results,
               &%{"role" => "tool", "tool_call_id" => &1.tool_use_id, "content" => &1.content}
             )
  end

  defp assert_durable(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.map(Enum.filter(raw, &(&1[:type] == "tool_use")), &{&1.id, &1.name, &1.input}) ==
             Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.map(
             Enum.filter(raw, &(&1[:type] == "tool_result")),
             &{&1.tool_use_id, &1.content, &1.projection, &1.is_error}
           ) ==
             Enum.map(results, &{&1.tool_use_id, &1.content, &1.projection, false})
  end
end
