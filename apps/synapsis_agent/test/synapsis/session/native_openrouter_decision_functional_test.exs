defmodule Synapsis.Session.NativeOpenRouterDecisionFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{Decisions, DisplayCatalog, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Decision, Decision.OpenRouter, ToolName}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{AgentConfigs, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::decision_evaluate"
  @call_id "ordinary-router-decision"
  @png "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA3sAAAAASUVORK5CYII="
  # The reference accepts syntax-bounded inline evidence without decoding codecs.
  @jpeg "data:image/jpeg;base64,AA=="
  @routing %{"provider" => %{"order" => ["TypeSafe"], "only" => ["TypeSafe"]}}
  @box %{"top" => 0.25, "bottom" => 0.75, "left" => 0.25, "right" => 0.76}
  @text_questions %{
    "damaged" => %{"type" => "boolean", "instructions" => "Is the parcel damaged?"},
    "route" => %{
      "type" => "choice",
      "instructions" => "Choose a team",
      "criteria" => %{"sales" => "New orders", "support" => "Support"}
    },
    "urgency" => %{
      "type" => "score",
      "instructions" => "Rate urgency",
      "criteria" => ["Low", "High"]
    }
  }
  @text_wire_questions Map.put(@text_questions, "damaged", %{
                         "type" => "noul",
                         "instructions" => "Is the parcel damaged?"
                       })
  @image_questions %{
    "present" => %{"type" => "boolean", "instructions" => "Is the product present?"},
    "target" => %{"type" => "box", "instructions" => "the red product in the photo"}
  }
  @image_wire_questions Map.put(@image_questions, "present", %{
                          "type" => "noul",
                          "instructions" => "Is the product present?"
                        })
  @text_usage %{
    "input_tokens" => 476,
    "output_tokens" => 70,
    "cost" => 0.000019992,
    "provider_units" => 3
  }

  for {label, model, input, expected_state, wire_questions, response, expected_result} <- [
        {"Jev 1.13 text and extended actual usage", "typesafe/jev-1.13",
         %{"state" => "  Supplied parcel evidence. 😀\n", "questions" => @text_questions},
         "  Supplied parcel evidence. 😀\n", @text_wire_questions,
         %{
           "model" => "typesafe/jev-1.13-20260917",
           "provider" => "TypeSafe",
           "answers" => %{
             "damaged" => %{"type" => "noul", "noul" => 0.37},
             "route" => %{
               "type" => "choice",
               "choice" => "support",
               "probabilities" => %{"sales" => 0.7, "support" => 0.2},
               "confidence" => 0.1
             },
             "urgency" => %{
               "type" => "score",
               "score" => 0.71,
               "probabilities" => %{"0" => 0.3, "1" => 0.69},
               "confidence" => 0.2
             }
           },
           "usage" => @text_usage
         },
         %{
           "model" => "typesafe/jev-1.13-20260917",
           "metadata" => %{"provider" => "TypeSafe"},
           "answers" => %{
             "damaged" => %{"type" => "boolean", "probabilityTrue" => 0.37},
             "route" => %{
               "type" => "choice",
               "choice" => "support",
               "probabilities" => %{"sales" => 0.7, "support" => 0.2},
               "confidence" => 0.1
             },
             "urgency" => %{
               "type" => "score",
               "score" => 0.71,
               "probabilities" => [0.3, 0.69],
               "confidence" => 0.2
             }
           },
           "usage" => %{
             "inputTokens" => 476,
             "outputTokens" => 70,
             "costUsd" => 0.000019992,
             "raw" => @text_usage
           }
         }},
        {"Jev 1.14 PNG box and zero cost", "typesafe/jev-1.14",
         %{
           "contractVersion" => 2,
           "state" => %{"type" => "image", "dataUri" => @png, "text" => "Listing photo"},
           "questions" => @image_questions
         }, ["Listing photo", %{"type" => "image_url", "image_url" => %{"url" => @png}}],
         @image_wire_questions,
         %{
           "model" => "typesafe/jev-1.14-served",
           "provider" => "TypeSafe",
           "answers" => %{
             "present" => %{"type" => "noul", "noul" => 0.91},
             "target" => %{"type" => "box", "box" => @box, "confidence" => 0.91}
           },
           "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "cost" => 0}
         },
         %{
           "model" => "typesafe/jev-1.14-served",
           "metadata" => %{"provider" => "TypeSafe"},
           "answers" => %{
             "present" => %{"type" => "boolean", "probabilityTrue" => 0.91},
             "target" => %{"type" => "box", "box" => @box, "confidence" => 0.91}
           },
           "usage" => %{"inputTokens" => 4, "outputTokens" => 0, "costUsd" => 0}
         }},
        {"Jev latest JPEG box and absent optional cost", "~typesafe/jev-latest",
         %{
           "contractVersion" => 2,
           "state" => %{"type" => "image", "dataUri" => @jpeg, "text" => ""},
           "questions" => %{
             "target" => %{"type" => "box", "instructions" => "Find the supplied target"}
           }
         }, ["", %{"type" => "image_url", "image_url" => %{"url" => @jpeg}}],
         %{"target" => %{"type" => "box", "instructions" => "Find the supplied target"}},
         %{
           "model" => "typesafe/jev-latest-served",
           "answers" => %{"target" => %{"type" => "box", "box" => @box, "confidence" => 0.82}},
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1}
         },
         %{
           "model" => "typesafe/jev-latest-served",
           "answers" => %{"target" => %{"type" => "box", "box" => @box, "confidence" => 0.82}},
           "usage" => %{"inputTokens" => 2, "outputTokens" => 1}
         }}
      ] do
    @model model
    @input input
    @expected_state expected_state
    @wire_questions wire_questions
    @response response
    @expected_result expected_result

    test "selected native #{label} keeps complete JSON and replays through a new Worker", %{
      tmp_dir: root
    } do
      h = harness(root, @model)
      install(h, @input, @response)
      trace_effects()
      SessionHarness.subscribe!(h.session.id)
      SessionHarness.ensure_running!(h.session.id)

      assert :ok =
               Worker.send_message(h.session.id, "Evaluate only the supplied OpenRouter fixture")

      assert_receive {:decision_outer, 0, initial}, 5_000
      assert_receive {:decision_descriptor, descriptor}, 5_000
      assert descriptor.backend == Decisions
      assert descriptor.backend_context.provider_type == "openrouter"
      assert descriptor.codex_exposure == :direct_model_only
      assert [%{"name" => name, "input_schema" => schema}] = initial["tools"]
      assert ToolName.decode(name) == @name
      assert schema == descriptor.schema
      assert schema["required"] == ["state", "questions"]
      assert @name in Profiles.supported_names()
      assert length(Profiles.supported_names()) == 62
      assert [%{category: :planning}] = Enum.filter(DisplayCatalog.list(), &(&1.name == @name))
      assert {:ok, []} = Models.list(provider_id: h.decision.id)
      assert_receive {:decision_native, request}, 10_000

      assert request == %{
               "model" => @model,
               "state" => @expected_state,
               "questions" => @wire_questions,
               "provider" => @routing["provider"]
             }

      assert_receive {:decision_outer, 1, following}, 10_000
      assert_receive {:decision_native_settled, [native]}, 5_000
      assert native.is_error == false
      assert [%{type: "text", text: public_json}] = native.content
      public = Jason.decode!(public_json)

      assert %{"status" => "ok", "result" => @expected_result, "provenance" => provenance} =
               public

      assert provenance["providerId"] == h.decision.id
      assert "synapsis-decision-v1-" <> hash = provenance["rubricVersion"]
      assert byte_size(hash) == 24
      assert {:ok, generation} = Ecto.UUID.cast(provenance["runtimeGeneration"])
      assert generation == descriptor.backend_context.runtime_generation
      assert native.details == public
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      [use, result] = decision_parts(h.session.id)
      assert %ToolUse{tool: @name, tool_use_id: @call_id, input: @input} = use
      assert %ToolResult{is_error: false, tool_use_id: @call_id, content: ^public_json} = result
      assert result.projection["result"]["details"] == public

      assert result.projection["result"]["content"] == [
               %{"type" => "text", "text" => public_json}
             ]

      assert_text_wire(following, public_json)
      assert_round_trip_and_store(h.session.id, [use, result])
      [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      monitor = Process.monitor(old)
      assert :ok = DynamicSupervisor.stop_session(h.session.id)
      assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
      SessionHarness.ensure_running!(h.session.id)
      [{new, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      refute new == old
      assert :ok = Worker.send_message(h.session.id, "Recall the completed OpenRouter decision")
      assert_receive {:decision_outer, 2, replay}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_text_wire(replay, public_json)
      assert decision_parts(h.session.id) == [use, result]
      assert_round_trip_and_store(h.session.id, [use, result])
      assert %{decision: 1, outer: 3} = Agent.get(h.counter, & &1)
      assert_once_effect(h, @input, @model)
    end
  end

  defp harness(root, model) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    fixture = Gaoxy.Test.open()

    {:ok, decision} =
      Providers.create(%{
        name: "native-router-decision-#{System.unique_integer([:positive])}",
        type: "openrouter",
        base_url: Gaoxy.Test.url(fixture, "/custom/api/v1/"),
        api_key_encrypted: "ordinary-router-fixture",
        config: %{
          "params" => %{"provider" => %{"order" => ["Configured"], "only" => ["TypeSafe"]}}
        }
      })

    on_exit(fn -> Providers.delete(decision.id) end)

    config =
      Map.put(h.agent_config.config, "decision", %{
        "provider" => decision.name,
        "model" => model,
        "params" => %{"provider" => %{"order" => ["TypeSafe"]}}
      })

    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "fixture"
             })

    Agent.update(h.counter, &Map.merge(&1, %{decision: 0, outer: 0}))
    Map.merge(h, %{decision: decision, decision_fixture: fixture})
  end

  defp install(h, input, response) do
    owner = self()

    Gaoxy.Test.stub(h.decision_fixture, "POST", "/custom/api/v1/systemone", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(h.counter, &Map.update!(&1, :decision, fn n -> n + 1 end))
      send(owner, {:decision_native, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {state.outer, %{state | outer: state.outer + 1}}
        end)

      send(owner, {:decision_outer, index, request})

      if index in [0, 1] do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        adapter = :sys.get_state(data.runtime_pid, 1_000)
        native = :sys.get_state(adapter.root, 1_000)

        if index == 0,
          do: send(owner, {:decision_descriptor, native.catalog.registry.tools[@name]}),
          else: send(owner, {:decision_native_settled, Map.values(native.run.tool_results)})
      end

      outer_response(conn, if(index == 0, do: input))
    end)
  end

  defp outer_response(conn, input) do
    {block, delta, stop} =
      if input do
        {%{
           "type" => "tool_use",
           "id" => @call_id,
           "name" => ToolName.encode(@name),
           "input" => %{}
         }, %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}
      else
        {%{"type" => "text", "text" => ""},
         %{"type" => "text_delta", "text" => "Decision result received"}, "end_turn"}
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
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end

  defp decision_parts(id),
    do:
      for(
        message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{tool: @name}, part) or match?(%ToolResult{tool_use_id: @call_id}, part),
        do: part
      )

  defp assert_text_wire(request, json) do
    blocks =
      Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

    assert [result] = Enum.filter(blocks, &(&1["type"] == "tool_result"))
    assert result["tool_use_id"] == @call_id
    assert result["is_error"] == false
    assert result["content"] == [%{"type" => "text", "text" => json}]
  end

  defp assert_round_trip_and_store(id, [_, result] = parts) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    assert [stored] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    assert stored.content == result.content
    assert stored.projection == result.projection
  end

  defp trace_effects do
    for {module, function, arity} <- [{Decisions, :execute, 1}, {OpenRouter, :evaluate, 2}] do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern({module, function, arity}, true, [:local])
    end

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])

      for {module, function, arity} <- [{Decisions, :execute, 1}, {OpenRouter, :evaluate, 2}],
          do: :erlang.trace_pattern({module, function, arity}, false, [:local])
    end)
  end

  defp assert_once_effect(h, input, model) do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    calls = drain_calls([])

    assert [{effect, Decisions, :execute, [operation]}] =
             Enum.filter(calls, &(elem(&1, 1) == Decisions))

    assert [{^effect, OpenRouter, :evaluate, [batch, config]}] =
             Enum.filter(calls, &(elem(&1, 1) == OpenRouter))

    assert operation.tool_name == @name
    assert operation.tool_call_id == @call_id
    assert operation.arguments == input
    assert {:ok, ^batch} = Decision.normalize(input)
    assert config.model == model
    assert config.params == @routing
    assert operation.backend_context.provider_type == "openrouter"
    assert is_integer(config.deadline)
    assert config.base_url == Gaoxy.Test.url(h.decision_fixture, "/custom/api/v1")
  end

  defp drain_calls(calls) do
    receive do
      {:trace, pid, :call, {module, function, arguments}} ->
        drain_calls([{pid, module, function, arguments} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
