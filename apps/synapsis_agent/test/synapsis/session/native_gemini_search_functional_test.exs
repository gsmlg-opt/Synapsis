defmodule Synapsis.Session.NativeGeminiSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"

  test "selected Gemini resolves ordinary citations once and replays complete durable results in a new Worker",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    {:ok, credential} =
      Synapsis.Credentials.create(%{
        name: harness.agent_name <> " Gemini search",
        key: "ordinary-native-gemini"
      })

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(harness)
      after
        Synapsis.Credentials.delete(credential.id)
      end
    end)

    Agent.update(harness.counter, &Map.merge(&1, %{search_requests: [], citation_requests: []}))
    install_search(harness)
    base = Gaoxy.Test.url(harness.provider.fixture, "/gemini/v1beta")
    host = URI.parse(base).host

    config =
      harness.agent_config.config
      |> Map.put("web_allowed_hosts", [String.upcase(host), host, "Ordinary.Example"])
      |> Map.put("web_search", %{
        "provider" => "gemini",
        "credential_id" => credential.id,
        "base_url" => base <> "///",
        "model" => " gemini-3.1-pro-preview ",
        "headers" => %{"X-Search-Workspace" => " ordinary native "},
        "timeout_ms" => 15_000,
        "cache_ttl_ms" => 60_000,
        "count" => 3
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})

    args = %{
      "query" => ~s( 雪🙂 "语言模型" site:example.org ),
      "count" => 2,
      "date_after" => "2026-10-12",
      "date_before" => "2026-10-18"
    }

    cached_args = Map.put(args, "count", 4)
    calls = [{"gemini-first", @name, args}, {"gemini-cached", @name, cached_args}]
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search Gemini")
    requests = for index <- 0..2, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    assert Map.keys(descriptors) == [@name]
    descriptor = descriptors[@name]
    assert descriptor.backend == Search
    assert descriptor.backend_context.config.provider == "gemini"
    assert descriptor.backend_context.config.credential_id == credential.id
    assert descriptor.backend_context.config.base_url == base
    assert descriptor.backend_context.config.model == "gemini-3.1-pro-preview"

    assert descriptor.backend_context.config.headers == %{
             "x-search-workspace" => "ordinary native"
           }

    assert descriptor.backend_context.config.timeout_ms == 15_000

    assert descriptor.backend_context.config.citation_allowed_hosts ==
             Enum.sort([host, "ordinary.example"])

    assert descriptor.backend_context.config.citation_policy == :declared_hosts_v1

    for group <- reference()["groups"] do
      assert descriptor.description == group["descriptor"]["description"], group["id"]

      assert descriptor.schema ==
               Map.put(group["descriptor"]["parameters"], "additionalProperties", false),
             group["id"]
    end

    assert hd(requests)["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => ToolName.encode(@name),
                 "description" => descriptor.description,
                 "parameters" => descriptor.schema
               }
             }
           ]

    original_parts = parts(harness.session.id)
    uses = Enum.filter(original_parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(original_parts, &match?(%ToolResult{}, &1))

    assert uses ==
             Enum.map(calls, fn {id, name, input} ->
               %ToolUse{tool_use_id: id, tool: name, input: input, status: :pending}
             end)

    assert Enum.map(results, & &1.tool_use_id) == ["gemini-first", "gemini-cached"]
    assert Enum.all?(results, &(&1.is_error == false))
    [first, cached] = Enum.map(results, &Jason.decode!(&1.content))

    assert Map.delete(first, "tookMs") == %{
             "kind" => "answer",
             "provider" => "gemini",
             "query" => args["query"],
             "content" =>
               "First ordinary paragraph. \nSecond ordinary paragraph.\n Third ordinary paragraph.",
             "citations" => [
               %{"url" => url(harness, "/publisher/article"), "title" => "First source"},
               %{"url" => url(harness, "/two")},
               %{"url" => url(harness, "/publisher/article"), "title" => "Duplicate source"},
               %{"url" => url(harness, "/news"), "title" => "Third source"}
             ]
           }

    assert is_integer(first["tookMs"]) and first["tookMs"] >= 0
    assert cached == Map.put(first, "cached", true)

    for result <- results do
      public = Jason.decode!(result.content)

      assert result.projection == %{
               "version" => 1,
               "result" =>
                 Map.merge(public, %{
                   "content" => result.content,
                   "structured" => public,
                   "is_error" => false
                 })
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
             original_parts ++
               [%Text{content: "Recall searches"}, %Text{content: "Searches complete"}]

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness, args)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 4
  end

  defp install_search(harness) do
    payload =
      Enum.find(reference()["groups"], &(&1["id"] == "ordered-answer-citations"))["httpPayload"]

    payload =
      update_in(
        payload,
        ["candidates", Access.at(0), "groundingMetadata", "groundingChunks"],
        fn chunks ->
          Enum.map(chunks, fn chunk ->
            update_in(chunk, ["web", "uri"], fn source -> url(harness, URI.parse(source).path) end)
          end)
        end
      )

    Gaoxy.Test.stub(
      harness.provider.fixture,
      "POST",
      "/gemini/v1beta/models/gemini-3.1-pro-preview:generateContent",
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        headers =
          Map.take(Map.new(conn.req_headers), ~w(content-type x-goog-api-key x-search-workspace))

        Agent.update(
          harness.counter,
          &%{
            &1
            | search_requests:
                &1.search_requests ++ [{conn.request_path, Jason.decode!(body), headers}]
          }
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(payload))
      end
    )

    for {path, status, location} <- [
          {"/one", 302, "./bridge"},
          {"/bridge", 307, "/publisher/article"},
          {"/publisher/article", 200, nil},
          {"/two", 200, nil},
          {"/three", 308, "/news"},
          {"/news", 200, nil}
        ] do
      Gaoxy.Test.stub(harness.provider.fixture, "HEAD", path, fn conn ->
        Agent.update(
          harness.counter,
          &%{&1 | citation_requests: &1.citation_requests ++ [{conn.method, conn.request_path}]}
        )

        conn = if location, do: Plug.Conn.put_resp_header(conn, "location", location), else: conn
        Plug.Conn.resp(conn, status, "")
      end)
    end
  end

  defp assert_effect(harness, args) do
    assert Agent.get(harness.counter, & &1.search_requests) == [
             {
               "/gemini/v1beta/models/gemini-3.1-pro-preview:generateContent",
               %{
                 "contents" => [%{"parts" => [%{"text" => String.trim(args["query"])}]}],
                 "tools" => [
                   %{
                     "google_search" => %{
                       "timeRangeFilter" => %{
                         "startTime" => "2026-10-12T00:00:00Z",
                         "endTime" => "2026-10-19T00:00:00Z"
                       }
                     }
                   }
                 ]
               },
               %{
                 "content-type" => "application/json",
                 "x-goog-api-key" => "ordinary-native-gemini",
                 "x-search-workspace" => "ordinary native"
               }
             }
           ]

    assert Enum.frequencies(Agent.get(harness.counter, & &1.citation_requests)) == %{
             {"HEAD", "/one"} => 2,
             {"HEAD", "/bridge"} => 2,
             {"HEAD", "/publisher/article"} => 2,
             {"HEAD", "/two"} => 1,
             {"HEAD", "/three"} => 1,
             {"HEAD", "/news"} => 1
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

  defp url(harness, path), do: Gaoxy.Test.url(harness.provider.fixture, path)

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
    Path.expand("../../fixtures/openclaw/488631c/gemini-search.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end
end
