defmodule Synapsis.Agent.Runtime.ProviderUsageFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Goal.State, as: GoalState
  alias Backplane.AiProtocol.Usage
  alias Synapsis.Agent.Runtime.{ProviderAdapter, ProviderEvents, ProviderUsage}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof

  test "Anthropic HTTP start and output snapshots produce one final inclusive usage report" do
    assert_http_usage(
      "anthropic",
      "/v1/messages",
      [
        %{
          "type" => "message_start",
          "message" => %{
            "usage" => %{
              "input_tokens" => 10,
              "cache_read_input_tokens" => 2,
              "cache_creation_input_tokens" => 4,
              "output_tokens" => 1
            }
          }
        },
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Hello"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 5, "cache_read_input_tokens" => 6}
        },
        %{"type" => "message_delta", "usage" => %{"output_tokens" => 5}},
        %{"type" => "message_stop"}
      ],
      %{input_tokens: 20, cached_tokens: 6, output_tokens: 5, reasoning_tokens: nil}
    )
  end

  test "Chat HTTP trailing cache revisions and repeated snapshots produce one final report" do
    final_usage = %{
      "prompt_tokens" => 20,
      "completion_tokens" => 8,
      "prompt_tokens_details" => %{"cached_tokens" => 6},
      "completion_tokens_details" => %{"reasoning_tokens" => 3},
      "total_tokens" => 28
    }

    assert_http_usage(
      "openai",
      "/v1/chat/completions",
      [
        %{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => "stop"}
          ]
        },
        %{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 20,
            "completion_tokens" => 8,
            "prompt_tokens_details" => %{"cached_tokens" => 2},
            "completion_tokens_details" => %{"reasoning_tokens" => 3},
            "total_tokens" => 28
          }
        },
        %{"choices" => [], "usage" => final_usage},
        %{"choices" => [], "usage" => final_usage}
      ],
      %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3},
      done: true
    )
  end

  test "Responses HTTP output already includes its reasoning token breakdown" do
    assert_http_usage(
      "openai_responses",
      "/v1/responses",
      [
        %{"type" => "response.output_text.delta", "delta" => "Hello"},
        %{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "model" => "observed-usage-fixture",
            "output" => [
              %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hello"}]}
            ],
            "usage" => %{
              "input_tokens" => 20,
              "input_tokens_details" => %{"cached_tokens" => 6},
              "output_tokens" => 8,
              "output_tokens_details" => %{"reasoning_tokens" => 3},
              "total_tokens" => 28
            }
          }
        }
      ],
      %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3},
      expected_model: "observed-usage-fixture"
    )
  end

  test "Google HTTP trailing usage includes thoughts and tool-use prompt tokens once" do
    final_usage = %{
      "promptTokenCount" => 20,
      "cachedContentTokenCount" => 6,
      "candidatesTokenCount" => 8,
      "thoughtsTokenCount" => 3,
      "toolUsePromptTokenCount" => 4,
      "totalTokenCount" => 35
    }

    assert_http_usage(
      "google",
      "/v1beta/models/usage-fixture:streamGenerateContent",
      [
        %{
          "candidates" => [
            %{
              "index" => 0,
              "content" => %{"parts" => [%{"text" => "Hello"}]},
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 20,
            "cachedContentTokenCount" => 2,
            "candidatesTokenCount" => 2,
            "thoughtsTokenCount" => 1,
            "totalTokenCount" => 23
          }
        },
        %{"usageMetadata" => final_usage},
        %{"usageMetadata" => final_usage}
      ],
      %{input_tokens: 24, cached_tokens: 6, output_tokens: 11, reasoning_tokens: 3}
    )
  end

  test "partial snapshots retain explicit fields and ProviderEvents buffers cache revisions" do
    observations = [
      {
        usage("anthropic", :snapshot, :partial, input_tokens: 10),
        %{input_tokens: nil, cached_tokens: nil, output_tokens: nil, reasoning_tokens: nil}
      },
      {
        usage("anthropic", :snapshot, :partial,
          cache_read_tokens: 6,
          cache_write_tokens: 4,
          output_tokens: 5
        ),
        %{input_tokens: 20, cached_tokens: 6, output_tokens: 5, reasoning_tokens: nil}
      },
      {
        usage("anthropic", :snapshot, :complete, cache_read_tokens: 8, cache_write_tokens: 2),
        %{input_tokens: 20, cached_tokens: 8, output_tokens: 5, reasoning_tokens: nil}
      },
      {
        usage("anthropic", :snapshot, :partial, output_tokens: nil),
        %{input_tokens: 20, cached_tokens: 8, output_tokens: 5, reasoning_tokens: nil}
      }
    ]

    assert ProviderUsage.snapshot(ProviderUsage.new()) == nil

    {_usage_state, events_state} =
      Enum.reduce(observations, {ProviderUsage.new(), ProviderEvents.new()}, fn
        {observation, expected}, {usage_state, events_state} ->
          usage_state = ProviderUsage.push(usage_state, observation)
          assert ProviderUsage.snapshot(usage_state) == expected

          assert {:ok, [], events_state} =
                   ProviderEvents.push(events_state, {:usage, observation})

          {usage_state, events_state}
      end)

    expected = %{
      type: :response_completed,
      message: %{role: :assistant, content: []},
      usage: %{input_tokens: 20, cached_tokens: 8, output_tokens: 5, reasoning_tokens: nil}
    }

    assert {:ok, ^expected} = ProviderEvents.finish(events_state)
    assert {:ok, ^expected} = ProviderEvents.finish(events_state)
  end

  test "equal numeric deltas add and an explicit snapshot reanchors partial deltas" do
    delta =
      usage("openai", :delta, :complete,
        input_tokens: 10,
        cache_read_tokens: 2,
        output_tokens: 3,
        reasoning_tokens: 1
      )

    state = ProviderUsage.push(ProviderUsage.new(), delta)

    assert ProviderUsage.snapshot(state) == %{
             input_tokens: 10,
             cached_tokens: 2,
             output_tokens: 3,
             reasoning_tokens: 1
           }

    state = ProviderUsage.push(state, delta)

    assert ProviderUsage.snapshot(state) == %{
             input_tokens: 20,
             cached_tokens: 4,
             output_tokens: 6,
             reasoning_tokens: 2
           }

    state =
      ProviderUsage.push(
        state,
        usage("openai", :delta, :partial,
          input_tokens: 1,
          output_tokens: 2,
          reasoning_tokens: 1
        )
      )

    assert ProviderUsage.snapshot(state) == %{
             input_tokens: 21,
             cached_tokens: nil,
             output_tokens: 8,
             reasoning_tokens: 3
           }

    state =
      ProviderUsage.push(
        state,
        usage("openai", :delta, :complete,
          input_tokens: 1,
          cache_read_tokens: 1,
          output_tokens: 1,
          reasoning_tokens: 0
        )
      )

    assert ProviderUsage.snapshot(state) == %{
             input_tokens: 22,
             cached_tokens: nil,
             output_tokens: 9,
             reasoning_tokens: 3
           }

    state =
      ProviderUsage.push(
        state,
        usage("openai", :snapshot, :complete,
          input_tokens: 30,
          cache_read_tokens: 6,
          output_tokens: 10,
          reasoning_tokens: 4
        )
      )

    assert ProviderUsage.snapshot(state) == %{
             input_tokens: 30,
             cached_tokens: 6,
             output_tokens: 10,
             reasoning_tokens: 4
           }
  end

  test "explicit zero snapshots and fresh attempt accumulators preserve independent totals" do
    first =
      ProviderUsage.push(
        ProviderUsage.new(),
        usage("openai_responses", :snapshot, :complete,
          input_tokens: 20,
          cache_read_tokens: 6,
          output_tokens: 8,
          reasoning_tokens: 3
        )
      )

    second =
      ProviderUsage.push(
        ProviderUsage.new(),
        usage("openai_responses", :snapshot, :complete,
          input_tokens: 0,
          cache_read_tokens: 0,
          output_tokens: 0,
          reasoning_tokens: 0
        )
      )

    assert ProviderUsage.snapshot(first) == %{
             input_tokens: 20,
             cached_tokens: 6,
             output_tokens: 8,
             reasoning_tokens: 3
           }

    assert ProviderUsage.snapshot(second) == %{
             input_tokens: 0,
             cached_tokens: 0,
             output_tokens: 0,
             reasoning_tokens: 0
           }

    assert ProviderUsage.snapshot(ProviderUsage.new()) == nil

    assert ProviderEvents.finish(ProviderEvents.new()) ==
             {:ok, %{type: :response_completed, message: %{role: :assistant, content: []}}}
  end

  test "native Goal accounting charges the final snapshot once across terminal repeats" do
    cases = [
      {
        "anthropic",
        [input_tokens: 10, cache_read_tokens: 6, cache_write_tokens: 4, output_tokens: 5],
        %{input_tokens: 20, cached_tokens: 6, output_tokens: 5, reasoning_tokens: nil},
        19
      },
      {
        "openai",
        [input_tokens: 20, cache_read_tokens: 6, output_tokens: 8, reasoning_tokens: 3],
        %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3},
        22
      },
      {
        "openai_responses",
        [input_tokens: 20, cache_read_tokens: 6, output_tokens: 8, reasoning_tokens: 3],
        %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3},
        22
      },
      {
        "google",
        [
          input_tokens: 20,
          cache_read_tokens: 6,
          output_tokens: 8,
          reasoning_tokens: 3,
          native_total: 35
        ],
        %{input_tokens: 24, cached_tokens: 6, output_tokens: 11, reasoning_tokens: 3},
        29
      }
    ]

    for {source, counters, expected_usage, expected_charge} <- cases do
      accumulator =
        ProviderUsage.push(ProviderUsage.new(), usage(source, :snapshot, :complete, counters))

      assert ProviderUsage.snapshot(accumulator) == expected_usage
      {:ok, initial} = GoalState.new(Ecto.UUID.generate(), [])

      {:ok, initial} =
        GoalState.create(initial, %{objective: "Account an ordinary final response"})

      receipt = %{
        receipt_id: "final-usage",
        thread_id: initial.thread_id,
        expected_goal_id: initial.goal.goal_id,
        run_id: "trusted-native-run",
        incarnation: 1,
        turn_id: "trusted-native-turn",
        revision: 1,
        type: :usage,
        payload:
          Map.merge(ProviderUsage.snapshot(accumulator), %{
            attempt_id: "trusted-native-attempt",
            identity: "trusted-native-final-usage",
            cumulative: true
          })
      }

      assert {:ok, once} = GoalState.account(initial, receipt)
      assert once.goal.tokens_used == expected_charge
      assert once.accounting_uncertain == false
      assert {:ok, ^once} = GoalState.account(once, receipt)

      terminal_repeat = %{receipt | receipt_id: "terminal-usage-repeat", revision: 2}
      assert {:ok, repeated} = GoalState.account(once, terminal_repeat)
      assert repeated.goal.tokens_used == expected_charge
      assert repeated.accounting_uncertain == false
      assert repeated.usage.totals.input_tokens == expected_usage.input_tokens
      assert repeated.usage.totals.cached_tokens == expected_usage.cached_tokens
      assert repeated.usage.totals.output_tokens == expected_usage.output_tokens
    end
  end

  test "a real native Conversation retains final HTTP usage and its terminal repeat" do
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["model"] == "usage-fixture"

      chunks = [
        %{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Native HTTP"}, "finish_reason" => "stop"}
          ]
        },
        %{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 20,
            "prompt_tokens_details" => %{"cached_tokens" => 2},
            "completion_tokens" => 8,
            "completion_tokens_details" => %{"reasoning_tokens" => 3},
            "total_tokens" => 28
          }
        },
        %{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 20,
            "prompt_tokens_details" => %{"cached_tokens" => 6},
            "completion_tokens" => 8,
            "completion_tokens_details" => %{"reasoning_tokens" => 3},
            "total_tokens" => 28
          }
        }
      ]

      body =
        Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <>
          "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, body)
    end)

    run_id = Ecto.UUID.generate()
    caller = start_supervised!(Task.Supervisor)

    context = %{
      provider_config: %{
        type: "openai",
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
        api_key: "fixture"
      },
      request_options: %{model: "usage-fixture"},
      stream_timeout: 5_000
    }

    options =
      Proof.options(run_id, nil,
        provider: ProviderAdapter,
        provider_context: context
      )

    pid = start_supervised!({Conversation, options})
    assert {:ok, _} = Proof.prompt(caller, pid, "Hello")

    assert_receive {:agent_runtime, ^run_id,
                    %{
                      type: :response_started,
                      run_id: ^run_id,
                      incarnation: 1,
                      step_id: step_id,
                      attempt_id: attempt_id
                    }},
                   3_000

    assert is_binary(step_id) and step_id != ""
    assert is_binary(attempt_id) and attempt_id != ""
    expected_usage = %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3}

    assert_receive {:agent_runtime, ^run_id,
                    %{
                      type: :usage_updated,
                      usage: ^expected_usage,
                      run_id: ^run_id,
                      incarnation: 1,
                      step_id: ^step_id,
                      attempt_id: ^attempt_id
                    }},
                   3_000

    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000
    status = Conversation.status(pid)

    assert List.last(status.messages) == %{
             role: :assistant,
             content: [%{type: :text, text: "Native HTTP"}]
           }

    assert status.conversation.usage == [
             %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3},
             %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3}
           ]
  end

  defp usage(source, mode, status, counters) do
    struct!(Usage, Keyword.merge(counters, source: source, mode: mode, status: status))
  end

  defp assert_http_usage(source, path, chunks, expected_usage, opts \\ []) do
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert is_map(Jason.decode!(body))
      body = Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      body = if opts[:done], do: body <> "data: [DONE]\n\n", else: body

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, body)
    end)

    request = %{
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      turn_id: "ordinary-turn",
      step_id: "ordinary-step",
      attempt_id: "ordinary-attempt",
      catalog_revision: 1,
      tools: [],
      messages: [%{role: :user, content: "Hello"}]
    }

    context = %{
      provider_config: %{
        type: source,
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
        api_key: "fixture"
      },
      request_options: %{model: "usage-fixture"},
      stream_timeout: 5_000
    }

    expected_start =
      Map.merge(
        Map.take(request, [:run_id, :incarnation, :turn_id, :step_id, :attempt_id]),
        %{type: :response_started}
      )

    expected_terminal = %{
      type: :response_completed,
      message: %{role: :assistant, content: [%{type: :text, text: "Hello"}]},
      usage: expected_usage
    }

    expected_terminal =
      case Keyword.fetch(opts, :expected_model) do
        {:ok, model} -> put_in(expected_terminal, [:message, :model], model)
        :error -> expected_terminal
      end

    assert Enum.to_list(ProviderAdapter.stream(request, context)) == [
             expected_start,
             %{type: :content_text_delta, delta: "Hello"},
             %{type: :usage_updated, usage: expected_usage},
             expected_terminal
           ]
  end
end
