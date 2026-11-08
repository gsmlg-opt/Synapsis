defmodule Synapsis.Session.NativeDecisionFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{Decisions, DisplayCatalog, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Decision, Decision.OpenAI, ToolName}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{AgentConfigs, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::decision_evaluate"
  @call_id "ordinary-decision"
  @image "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA3sAAAAASUVORK5CYII="
  @questions %{
    "damaged" => %{
      "type" => "boolean",
      "instructions" => "Is the parcel damaged?",
      "criteria" => %{"true" => "Damaged parcel", "false" => nil}
    },
    "route" => %{
      "type" => "choice",
      "instructions" => %{"task" => "Choose route"},
      "criteria" => %{"sales" => ["New order"], "support" => %{"team" => "support"}}
    },
    "urgency" => %{"type" => "score", "criteria" => ["Low", %{"level" => "Medium"}, nil]}
  }
  @wire_questions [
    %{
      "type" => "predicate",
      "name" => "damaged",
      "instructions" =>
        "Is the parcel damaged?\nTrue criterion: Damaged parcel\nFalse criterion: null"
    },
    %{
      "type" => "choice",
      "name" => "route",
      "instructions" => "{\"task\":\"Choose route\"}",
      "choices" => [
        %{"value" => "sales", "description" => "[\"New order\"]"},
        %{"value" => "support", "description" => "{\"team\":\"support\"}"}
      ]
    },
    %{
      "type" => "score",
      "name" => "urgency",
      "instructions" => "",
      "levels" => [
        %{"label" => "0", "description" => "Low"},
        %{"label" => "1", "description" => "{\"level\":\"Medium\"}"},
        %{"label" => "2", "description" => "null"}
      ]
    }
  ]
  @provider_response %{
    "model" => "returned-decision-model",
    "answers" => [
      %{"name" => "damaged", "type" => "predicate", "probability" => 0.95},
      %{
        "name" => "route",
        "type" => "choice",
        "choice" => "support",
        "confidence" => 1.7,
        "probabilities" => [
          %{"value" => "support", "probability" => 0.2},
          %{"value" => "sales", "probability" => 0.7}
        ]
      },
      %{
        "name" => "urgency",
        "type" => "score",
        "score" => 1.25,
        "confidence" => -0.2,
        "probabilities" => [
          %{"label" => "2", "value" => 2, "probability" => 0.3},
          %{"label" => "0", "value" => 0, "probability" => 0.05},
          %{"label" => "1", "value" => 1, "probability" => 0.65}
        ]
      }
    ],
    "usage" => %{"input_tokens" => 42, "output_tokens" => 0, "total_tokens" => 42}
  }
  @expected_result %{
    "model" => "returned-decision-model",
    "answers" => %{
      "damaged" => %{"type" => "boolean", "probabilityTrue" => 0.95},
      "route" => %{
        "type" => "choice",
        "choice" => "support",
        "confidence" => 1.7,
        "probabilities" => %{"sales" => 0.7, "support" => 0.2}
      },
      "urgency" => %{
        "type" => "score",
        "score" => 1.25,
        "confidence" => -0.2,
        "probabilities" => [0.05, 0.65, 0.3]
      }
    },
    "usage" => %{"inputTokens" => 42, "outputTokens" => 0}
  }

  for {label, state, version, expected_input} <- [
        {"legacy text", "  The parcel is damaged. 😀\n", nil, "  The parcel is damaged. 😀\n"},
        {"tagged JSON",
         %{"type" => "json", "value" => %{"report" => "The parcel is damaged", "count" => 2}}, 2,
         "{\"count\":2,\"report\":\"The parcel is damaged\"}"},
        {"inline image",
         %{"type" => "image", "dataUri" => @image, "text" => "Inspect supplied image only"}, 2,
         [
           %{
             "role" => "user",
             "content" => [
               %{"type" => "input_text", "text" => "Inspect supplied image only"},
               %{"type" => "input_image", "image_url" => @image}
             ]
           }
         ]}
      ] do
    @input Map.merge(
             %{"state" => state, "questions" => @questions},
             if(version, do: %{"contractVersion" => version}, else: %{})
           )
    @expected_input expected_input
    test "selected native #{label} decision settles complete JSON and replays through a new Worker",
         %{tmp_dir: root} do
      h = harness(root)
      install(h, @input)
      trace_effects()
      SessionHarness.subscribe!(h.session.id)
      SessionHarness.ensure_running!(h.session.id)

      assert :ok =
               Worker.send_message(h.session.id, "Evaluate only the supplied decision fixture")

      assert_receive {:decision_outer, 0, initial}, 5_000
      assert_receive {:decision_descriptor, descriptor}, 5_000
      assert descriptor.backend == Decisions
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
               "model" => "explicit-decision-model",
               "input" => @expected_input,
               "questions" => @wire_questions
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
      assert {:ok, _} = Base.decode16(hash, case: :lower)
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
      assert :ok = Worker.send_message(h.session.id, "Recall the completed decision")
      assert_receive {:decision_outer, 2, replay}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_text_wire(replay, public_json)
      assert decision_parts(h.session.id) == [use, result]
      assert_round_trip_and_store(h.session.id, [use, result])
      assert %{decision: 1, outer: 3} = Agent.get(h.counter, & &1)
      assert_once_effect(h, @input)
    end
  end

  defp harness(root) do
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
        name: "native-decision-#{System.unique_integer([:positive])}",
        type: "openai_responses",
        base_url: Gaoxy.Test.url(fixture, "/custom/api/v1/"),
        api_key_encrypted: "ordinary-decision-fixture"
      })

    on_exit(fn -> Providers.delete(decision.id) end)

    config =
      Map.put(h.agent_config.config, "decision", %{
        "provider" => decision.name,
        "model" => "explicit-decision-model"
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

  defp install(h, input) do
    owner = self()

    Gaoxy.Test.stub(h.decision_fixture, "POST", "/custom/api/v1/decisions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(h.counter, &Map.update!(&1, :decision, fn n -> n + 1 end))
      send(owner, {:decision_native, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(@provider_response))
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
    for {module, function, arity} <- [{Decisions, :execute, 1}, {OpenAI, :evaluate, 2}] do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern({module, function, arity}, true, [:local])
    end

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])

      for {module, function, arity} <- [{Decisions, :execute, 1}, {OpenAI, :evaluate, 2}],
          do: :erlang.trace_pattern({module, function, arity}, false, [:local])
    end)
  end

  defp assert_once_effect(h, input) do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    calls = drain_calls([])

    assert [{effect, Decisions, :execute, [operation]}] =
             Enum.filter(calls, &(elem(&1, 1) == Decisions))

    assert [{^effect, OpenAI, :evaluate, [batch, config]}] =
             Enum.filter(calls, &(elem(&1, 1) == OpenAI))

    assert operation.tool_name == @name
    assert operation.tool_call_id == @call_id
    assert operation.arguments == input
    assert {:ok, ^batch} = Decision.normalize(input)
    assert config.model == "explicit-decision-model"
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
