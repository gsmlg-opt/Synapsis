defmodule Synapsis.Session.NativeParallelSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"

  test "selected paid Parallel preserves factory schema session threading and completed history across ordinary Worker replacement",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    {:ok, credential} =
      Synapsis.Credentials.create(%{
        name: harness.agent_name <> " Parallel",
        key: "ordinary-native-parallel"
      })

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(harness)
      after
        Synapsis.Credentials.delete(credential.id)
      end
    end)

    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    install_search(harness)

    config =
      Map.put(harness.agent_config.config, "web_search", %{
        "provider" => "parallel",
        "credential_id" => credential.id,
        "base_url" => Gaoxy.Test.url(harness.provider.fixture, "/ordinary/?view=native#section"),
        "timeout_ms" => 5000,
        "cache_ttl_ms" => 60_000,
        "count" => 3
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})

    args = %{
      "objective" => " Compare ordinary research sources 雪🙂 ",
      "search_queries" => [" first source 雪 ", "first source 雪", " ", " second source 🙂 "],
      "count" => 3,
      "client_model" => " gpt-6-astra "
    }

    followup = %{
      "objective" => " Follow up ordinary research findings 🙂 ",
      "search_queries" => [
        " fresh source evidence 雪 ",
        " fresh source evidence 雪 ",
        " alternate evidence 🙂 "
      ],
      "count" => 3,
      "session_id" => " parallel-session ",
      "client_model" => " claude-opus-4-7 "
    }

    calls = [
      {"parallel-first", @name, args},
      {"parallel-cached", @name, args},
      {"parallel-followup", @name, followup}
    ]

    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Research with Parallel")
    requests = for index <- 0..3, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    assert Map.keys(descriptors) == [@name]
    assert descriptors[@name].backend == Search
    assert descriptors[@name].backend_context.config.provider == "parallel"
    assert descriptors[@name].backend_context.config.credential_id == credential.id

    assert descriptors[@name].backend_context.config.base_url ==
             Gaoxy.Test.url(harness.provider.fixture, "/ordinary/v1/search?view=native")

    assert descriptors[@name].description == description()
    assert descriptors[@name].schema == schema()

    assert hd(requests)["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => ToolName.encode(@name),
                 "description" => description(),
                 "parameters" => schema()
               }
             }
           ]

    parts = parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))

    assert uses ==
             Enum.map(calls, fn {id, name, input} ->
               %ToolUse{tool_use_id: id, tool: name, input: input, status: :pending}
             end)

    assert Enum.map(results, & &1.tool_use_id) == [
             "parallel-first",
             "parallel-cached",
             "parallel-followup"
           ]

    assert Enum.all?(results, &(&1.is_error == false))
    [first, cached, last] = Enum.map(results, &Jason.decode!(&1.content))

    assert Map.delete(first, "tookMs") ==
             expected(
               "Compare ordinary research sources 雪🙂",
               ["first source 雪", "second source 🙂"],
               1
             )

    assert is_integer(first["tookMs"])
    assert first["tookMs"] >= 0
    assert cached == first |> Map.delete("sessionId") |> Map.put("cached", true)

    assert Map.delete(last, "tookMs") ==
             expected(
               "Follow up ordinary research findings 🙂",
               ["fresh source evidence 雪", "alternate evidence 🙂"],
               2
             )

    assert is_integer(last["tookMs"])
    assert last["tookMs"] >= 0

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
    assert_effect(harness)
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
    assert :ok = Worker.send_message(harness.session.id, "Recall Parallel research")
    replay = request(4)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             parts ++
               [%Text{content: "Recall Parallel research"}, %Text{content: "Searches complete"}]

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 5
  end

  defp description do
    "Search the web using Parallel. Returns ranked, LLM-optimized dense excerpts from web sources. Pass an `objective` describing the underlying question along with 2-3 short keyword `search_queries` (Parallel's recommended pairing). For multi-step research, thread the prior result's `sessionId` back in as `session_id` to keep Parallel's context grouped."
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "objective" => %{
          "type" => "string",
          "description" =>
            "Natural-language description of the underlying question or goal driving the search. Should be self-contained with enough context to understand the intent. Used together with search_queries to focus results on the most relevant content.",
          "maxLength" => 5000
        },
        "search_queries" => %{
          "type" => "array",
          "description" =>
            "Concise keyword search queries, 3-6 words each. Provide 2-3 diverse queries for best results (max 5). Vary entity names, synonyms, and angles. Each query is a keyword phrase, not a sentence; do not use site: operators.",
          "items" => %{"type" => "string", "maxLength" => 200},
          "minItems" => 1,
          "maxItems" => 5
        },
        "count" => %{
          "type" => "integer",
          "description" => "Number of results to return (1-40).",
          "minimum" => 1,
          "maximum" => 40
        },
        "session_id" => %{
          "type" => "string",
          "description" =>
            "Optional session id returned by an earlier Parallel search. Pass it on follow-up searches that are part of the same task to keep Parallel's server-side context grouped (look for `sessionId` in the prior tool result).",
          "maxLength" => 1000
        },
        "client_model" => %{
          "type" => "string",
          "description" =>
            "The identifier of the LLM model making this tool call (e.g. 'claude-opus-4-7', 'gpt-6-astra', 'gemini-3.1-pro'). Pass the exact active model slug verbatim; never shorten or substitute a family alias like 'gpt-5'. Lets Parallel tailor default settings for your model's capabilities.",
          "maxLength" => 100
        }
      },
      "required" => ["objective", "search_queries"],
      "additionalProperties" => false
    }
  end

  defp expected(objective, queries, index) do
    %{
      "kind" => "results",
      "provider" => "parallel",
      "objective" => objective,
      "searchQueries" => queries,
      "count" => 3,
      "results" => rows(),
      "searchId" => "parallel-search-#{index}",
      "sessionId" => "parallel-session",
      "warnings" => [%{"code" => "source_notice", "detail" => " Ordinary notice 雪 "}],
      "usage" => [%{"name" => "search", "count" => 1}]
    }
  end

  defp rows do
    for index <- 1..3 do
      %{
        "title" => " Source #{index} 雪 ",
        "url" => "https://SOURCES.EXAMPLE:443/research/#{index}?q=ordinary#part",
        "description" => " Passage #{index} 雪 \n\n Context #{index} 🙂 ",
        "siteName" => "sources.example",
        "published" => " 2026-11-0#{index} ",
        "excerpts" => [" Passage #{index} 雪 ", " Context #{index} 🙂 "]
      }
    end
  end

  defp install_search(harness) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/ordinary/v1/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          entries =
            state.search_requests ++ [{conn.request_path, conn.query_string, Jason.decode!(body)}]

          {length(entries), %{state | search_requests: entries}}
        end)

      payload = %{
        "search_id" => "parallel-search-#{index}",
        "session_id" => "parallel-session",
        "warnings" => [%{"code" => "source_notice", "detail" => " Ordinary notice 雪 "}],
        "usage" => [%{"name" => "search", "count" => 1}],
        "results" =>
          for(
            index <- 1..3,
            do: %{
              "title" => " Source #{index} 雪 ",
              "url" => "https://SOURCES.EXAMPLE:443/research/#{index}?q=ordinary#part",
              "publish_date" => " 2026-11-0#{index} ",
              "excerpts" => [" Passage #{index} 雪 ", " Context #{index} 🙂 "]
            }
          )
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp assert_effect(harness) do
    assert Agent.get(harness.counter, & &1.search_requests) == [
             {"/ordinary/v1/search", "view=native",
              %{
                "objective" => "Compare ordinary research sources 雪🙂",
                "search_queries" => ["first source 雪", "second source 🙂"],
                "advanced_settings" => %{"max_results" => 3},
                "client_model" => "gpt-6-astra"
              }},
             {"/ordinary/v1/search", "view=native",
              %{
                "objective" => "Follow up ordinary research findings 🙂",
                "search_queries" => ["fresh source evidence 雪", "alternate evidence 🙂"],
                "advanced_settings" => %{"max_results" => 3},
                "session_id" => "parallel-session",
                "client_model" => "claude-opus-4-7"
              }}
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
