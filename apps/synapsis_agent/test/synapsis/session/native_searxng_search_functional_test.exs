defmodule Synapsis.Session.NativeSearxngSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Session, as: NativeSession
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"

  setup %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    %{harness: harness}
  end

  test "selected keyless SearXNG defaults reach the actual Worker catalog", %{harness: harness} do
    base = Gaoxy.Test.url(harness.provider.fixture, "/ordinary/searxng")
    configure(harness, %{"provider" => "searxng", "base_url" => base})
    admitted = assert_admitted(harness)
    install_provider(harness, [])
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Describe available tools")
    initial = request(0)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, _}, 5000
    assert Map.keys(descriptors) == [@name]
    descriptor = descriptors[@name]
    assert descriptor.backend == Search
    assert descriptor.schema == admitted.registry.tools[@name].schema
    assert descriptor.description == admitted.registry.tools[@name].description

    assert descriptor.backend_context.config == %{
             provider: "searxng",
             credential_id: nil,
             base_url: base,
             timeout_ms: 20_000,
             cache_ttl_ms: 900_000,
             count: 5,
             mode: "web",
             categories: nil,
             language: nil
           }

    assert_descriptor(descriptor)
    assert initial["tools"] == wire_tools(descriptor)
    assert_wire(initial, [], [])
    assert Enum.filter(parts(harness.session.id), &match?(%ToolUse{}, &1)) == []
    assert Agent.get(harness.counter, & &1.search_requests) == []
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 1
  end

  test "SearXNG raw calls cached current query and category fallback survive ordinary completed Worker replacement",
       %{harness: harness} do
    base = Gaoxy.Test.url(harness.provider.fixture, "/ordinary/searxng")

    configure(harness, %{
      "provider" => "searxng",
      "base_url" => " " <> base <> "/// ",
      "categories" => " news ",
      "language" => " en "
    })

    args = %{
      "query" => " Ordinary sources 雪🙂 ",
      "count" => 3,
      "categories" => "news",
      "language" => "en"
    }

    cached_args = %{"query" => String.trim(args["query"]), "count" => 3}

    followup = %{
      "query" => " Fresh sources 雪🙂 ",
      "count" => 3,
      "categories" => "science,news",
      "language" => "de"
    }

    calls = [
      {"searxng-first", @name, args},
      {"searxng-cached", @name, cached_args},
      {"searxng-followup", @name, followup}
    ]

    admitted = assert_admitted(harness)
    install_search(harness)
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search SearXNG")
    requests = for index <- 0..3, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    assert Map.keys(descriptors) == [@name]
    descriptor = descriptors[@name]
    assert descriptor.backend == Search
    assert descriptor.schema == admitted.registry.tools[@name].schema

    assert descriptor.backend_context.config == %{
             provider: "searxng",
             credential_id: nil,
             base_url: base,
             timeout_ms: 20_000,
             cache_ttl_ms: 900_000,
             count: 5,
             mode: "web",
             categories: "news",
             language: "en"
           }

    assert_descriptor(descriptor)

    for req <- requests, do: assert(req["tools"] == wire_tools(descriptor))

    original_parts = parts(harness.session.id)
    uses = Enum.filter(original_parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(original_parts, &match?(%ToolResult{}, &1))

    assert uses ==
             Enum.map(calls, fn {id, name, input} ->
               %ToolUse{tool_use_id: id, tool: name, input: input, status: :pending}
             end)

    assert Enum.map(results, & &1.tool_use_id) == [
             "searxng-first",
             "searxng-cached",
             "searxng-followup"
           ]

    assert Enum.all?(results, &(&1.is_error == false))
    [first, cached, last] = Enum.map(results, &Jason.decode!(&1.content))
    assert Map.delete(first, "tookMs") == expected(args["query"], first_rows())
    assert is_integer(first["tookMs"]) and first["tookMs"] >= 0
    assert cached == first |> Map.put("query", cached_args["query"]) |> Map.put("cached", true)
    assert Map.delete(last, "tookMs") == expected(followup["query"], fallback_rows())
    assert is_integer(last["tookMs"]) and last["tookMs"] >= 0

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
    assert_effect(harness, args, followup)
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
    assert :ok = Worker.send_message(harness.session.id, "Recall SearXNG searches")
    replay = request(4)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_replay_root, replay_root}, 5000
    assert is_pid(replay_root)
    refute Process.alive?(replay_root)
    {_, replay_worker_data} = :sys.get_state(new_worker)
    assert :sys.get_state(replay_worker_data.runtime_pid).root == nil
    assert replay["tools"] == wire_tools(descriptor)
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             original_parts ++
               [%Text{content: "Recall SearXNG searches"}, %Text{content: "Searches complete"}]

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness, args, followup)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 5
  end

  defp configure(harness, search) do
    config = Map.put(harness.agent_config.config, "web_search", search)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})
  end

  defp assert_admitted(harness) do
    session = start_supervised!({NativeSession, owner_pid: self()})

    authority = %{
      caller: "native-searxng-functional",
      run_id: Ecto.UUID.generate(),
      grants: [@name],
      tool_revision: 1,
      tool_revisions: %{@name => 1}
    }

    assert {:ok, binding} = NativeSession.bind(session, authority)
    context = %{agent: %{name: harness.agent_name}}
    identity = %{run_id: authority.run_id, session_id: harness.session.id}
    assert {:ok, [bundle]} = Search.bundles(context, identity, authority, [@name], binding)
    assert {:ok, %{status: :confirmed}} = NativeSession.close(session)
    bundle
  end

  defp assert_descriptor(descriptor) do
    assert descriptor.description ==
             "Search the web using a self-hosted SearXNG instance. Returns titles, URLs, and snippets."

    assert descriptor.schema == %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "description" => "Search query string."},
               "count" => %{
                 "type" => "integer",
                 "description" => "Number of results to return (1-10).",
                 "minimum" => 1,
                 "maximum" => 10
               },
               "categories" => %{
                 "type" => "string",
                 "description" =>
                   "Optional comma-separated search categories such as general, news, or science."
               },
               "language" => %{
                 "type" => "string",
                 "description" => "Optional language code for results such as en, de, or fr."
               }
             },
             "required" => ["query"],
             "additionalProperties" => false
           }

    for group <- reference()["groups"] do
      assert descriptor.description == group["descriptor"]["description"], group["id"]

      # Native admission requires query; the source schema already uses integer count.
      assert descriptor.schema ==
               Map.put(group["descriptor"]["parameters"], "required", ["query"]),
             group["id"]
    end
  end

  defp wire_tools(descriptor) do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => ToolName.encode(@name),
          "description" => descriptor.description,
          "parameters" => descriptor.schema
        }
      }
    ]
  end

  defp expected(query, rows) do
    %{
      "kind" => "results",
      "provider" => "searxng",
      "query" => query,
      "count" => length(rows),
      "results" => rows
    }
  end

  defp first_rows do
    [
      %{
        "title" => "First ordinary title 雪",
        "url" => "https://www.sources.example/one",
        "snippet" => "First ordinary snippet 🙂.",
        "siteName" => "www.sources.example"
      },
      %{
        "title" => "Second ordinary title",
        "url" => "https://news.example/two",
        "snippet" => "Second ordinary snippet.",
        "siteName" => "news.example"
      }
    ]
  end

  defp fallback_rows do
    [
      %{
        "title" => "Fresh general source 雪",
        "url" => "https://research.example/fresh",
        "snippet" => "Fresh general snippet 🙂.",
        "siteName" => "research.example"
      }
    ]
  end

  defp install_search(harness) do
    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/ordinary/searxng/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      query = URI.decode_query(conn.query_string)

      observed = %{
        "method" => conn.method,
        "path" => conn.request_path,
        "query" => query,
        "headers" => Map.take(Map.new(conn.req_headers), ["accept"]),
        "body" => body
      }

      Agent.update(harness.counter, &%{&1 | search_requests: &1.search_requests ++ [observed]})

      rows =
        case query["categories"] do
          "news" ->
            [
              %{
                "title" => " First ordinary title 雪 ",
                "url" => "https://www.sources.example/one",
                "content" => " First ordinary snippet 🙂. ",
                "img_src" => "https://images.example/one.png"
              },
              %{
                "title" => "Second ordinary title",
                "url" => "https://news.example/two",
                "content" => "Second ordinary snippet."
              }
            ]

          "science,news" ->
            []

          "general" ->
            [
              %{
                "title" => " Fresh general source 雪 ",
                "url" => "https://research.example/fresh",
                "content" => " Fresh general snippet 🙂. ",
                "img_src" => "https://images.example/fresh.png"
              }
            ]
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => rows}))
    end)
  end

  defp assert_effect(harness, args, followup) do
    assert Agent.get(harness.counter, & &1.search_requests) == [
             expected_request(String.trim(args["query"]), "news", "en"),
             expected_request(String.trim(followup["query"]), "science,news", "de"),
             expected_request(String.trim(followup["query"]), "general", "de")
           ]
  end

  defp expected_request(query, categories, language) do
    %{
      "method" => "GET",
      "path" => "/ordinary/searxng/search",
      "query" => %{
        "q" => query,
        "format" => "json",
        "categories" => categories,
        "language" => language
      },
      "headers" => %{"accept" => "application/json"},
      "body" => ""
    }
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

      if index == 0 or index == length(calls) + 1 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker)
        runtime = :sys.get_state(data.runtime_pid)

        if index == 0 do
          send(
            owner,
            {:search_descriptors, :sys.get_state(runtime.root).catalog.registry.tools,
             runtime.root}
          )
        else
          send(owner, {:search_replay_root, runtime.root})
        end
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

  defp reference do
    Path.expand("../../fixtures/openclaw/488631c/searxng-search.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end
end
