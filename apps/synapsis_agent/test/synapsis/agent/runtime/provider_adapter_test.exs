defmodule Synapsis.Agent.Runtime.ProviderAdapterTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Synapsis.Agent.Runtime.ProviderAdapter
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof

  setup do
    bypass = Bypass.open()

    context = %{
      provider_config: %{
        type: "openai",
        base_url: "http://localhost:#{bypass.port}",
        api_key: "fixture"
      },
      request_options: %{model: "gpt-test", system_prompt: "Host instruction"},
      tools: [],
      stream_timeout: 2_000
    }

    request = %{
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      turn_id: "t",
      step_id: "s",
      attempt_id: "a",
      messages: [%{role: :user, content: "Hello"}]
    }

    %{bypass: bypass, context: context, request: request}
  end

  test "is lazy and uses the host transport for text, usage and canonical terminal", ctx do
    owner = self()

    Bypass.expect_once(ctx.bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:wire_request, Jason.decode!(body)})

      sse(conn, [
        chunk(%{"content" => "Hello"}),
        %{
          "choices" => [],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}
        },
        chunk(%{}, "stop")
      ])
    end)

    stream = ProviderAdapter.stream(ctx.request, ctx.context)
    refute_receive {:wire_request, _}, 30
    events = Enum.to_list(stream)
    assert_receive {:wire_request, wire}
    assert wire["model"] == "gpt-test"

    assert %{"role" => "system", "content" => [%{"type" => "text", "text" => "Host instruction"}]} in wire[
             "messages"
           ]

    assert hd(events).type == :response_started
    assert hd(events).attempt_id == "a"
    assert %{type: :content_text_delta, delta: "Hello"} in events
    assert Enum.any?(events, &(&1.type == :usage_updated and &1.usage.output_tokens == 1))

    assert List.last(events) == %{
             type: :response_completed,
             message: %{role: :assistant, content: [%{type: :text, text: "Hello"}]}
           }

    refute_receive {:provider_chunk, _}
    refute_receive :provider_done
  end

  test "a real HTTP stream completes a Backplane conversation", ctx do
    Bypass.expect_once(ctx.bypass, "POST", "/v1/chat/completions", fn conn ->
      sse(conn, [chunk(%{"content" => "From HTTP"}), chunk(%{}, "stop")])
    end)

    caller = start_supervised!(Task.Supervisor)

    options =
      Proof.options(ctx.request.run_id, nil,
        provider: ProviderAdapter,
        provider_context: ctx.context
      )

    pid = start_supervised!({Conversation, options})
    assert {:ok, _} = Proof.prompt(caller, pid, "Hello")
    run_id = ctx.request.run_id
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000

    assert List.last(Conversation.status(pid).messages).content == [
             %{type: :text, text: "From HTTP"}
           ]
  end

  test "maps indexed tool calls and trusts host tool definitions", ctx do
    Bypass.expect_once(ctx.bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [%{"function" => %{"name" => "skill"}}] = Jason.decode!(body)["tools"]

      sse(conn, [
        chunk(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "c",
              "type" => "function",
              "function" => %{"name" => "skill", "arguments" => "{\"name\":\"review\"}"}
            }
          ]
        }),
        chunk(%{}, "tool_calls")
      ])
    end)

    context = %{
      ctx.context
      | tools: [
          %{
            name: "skill",
            description: "Load a skill",
            parameters: Synapsis.Tool.Skill.parameters()
          }
        ]
    }

    events = Enum.to_list(ProviderAdapter.stream(ctx.request, context))

    assert %{
             type: :tool_call_completed,
             tool_call: %{id: "c", name: "skill", arguments: %{"name" => "review"}}
           } in events

    assert [%{type: :tool_call, id: "c"}] = List.last(events).message.content
  end

  test "HTTP failure emits exactly one terminal error", ctx do
    Bypass.expect_once(ctx.bypass, fn conn -> Plug.Conn.resp(conn, 500, "fixture failure") end)
    events = Enum.to_list(ProviderAdapter.stream(ctx.request, ctx.context))

    assert [%{type: :response_failed}] =
             Enum.filter(events, &(&1.type in [:response_failed, :response_completed]))
  end

  test "signed reasoning and image history replay through the actual Anthropic codec", ctx do
    config =
      Map.merge(ctx.context.provider_config, %{
        type: "anthropic",
        name: "primary",
        account: "account-a"
      })

    context = %{ctx.context | provider_config: config, request_options: %{model: "claude-test"}}

    request = %{
      ctx.request
      | messages: [
          %{
            role: :user,
            content: [
              %{type: :text, text: "Describe"},
              %{type: :image, media_type: "image/png", data: "AA=="}
            ]
          }
        ]
    }

    Bypass.expect_once(ctx.bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert [%{"type" => "text"}, %{"type" => "image", "source" => %{"data" => "AA=="}}] =
               Jason.decode!(body)["messages"] |> hd() |> Map.fetch!("content")

      events = [
        %{"type" => "message_start", "message" => %{"id" => "m"}},
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "thinking", "thinking" => ""}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "private"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "signature_delta", "signature" => "signed"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "message_stop"}
      ]

      body = Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.resp(200, body)
    end)

    events = Enum.to_list(ProviderAdapter.stream(request, context))
    assert %{type: :response_completed, message: message} = List.last(events)
    assert [%{type: :reasoning, text: "private", provider_states: [state]}] = message.content
    assert state["affinity"]["profile"] == "primary"
    assert state["affinity"]["account"] == "account-a"
    assert state["payload"]["signature"] == "signed"

    Bypass.expect_once(ctx.bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assistant = Enum.find(Jason.decode!(body)["messages"], &(&1["role"] == "assistant"))

      assert [%{"type" => "thinking", "thinking" => "private", "signature" => "signed"}] =
               assistant["content"]

      Plug.Conn.resp(
        conn,
        200,
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
      )
    end)

    request = %{
      request
      | messages: request.messages ++ [message, %{role: :user, content: "Continue"}]
    }

    assert %{type: :response_completed} =
             ProviderAdapter.stream(request, context) |> Enum.to_list() |> List.last()

    changed = %{context | request_options: %{model: "different-model"}}

    assert [%{type: :response_failed, error: %Backplane.AiProtocol.Error{kind: :incompatible}}] =
             Enum.to_list(ProviderAdapter.stream(request, changed))
  end

  test "HTTP tool turn loads an assigned skill and sends the result back to the provider", ctx do
    entry =
      struct!(Synapsis.SkillCatalog.Entry, %{
        authority: :synapsis,
        source_id: "proof",
        skill_id: "review",
        name: "review",
        locator: "proof:review",
        body: "---\nname: review\ndescription: Review code\n---\nReview body",
        loader: %{type: :inline, canonical?: true}
      })

    {:ok, registration} = Synapsis.Tool.Registry.lookup("skill")

    host_context = %{
      run_id: ctx.request.run_id,
      project_path: File.cwd!(),
      registration: registration,
      permission_mode: "ask",
      attended?: false,
      skill_catalog: [entry]
    }

    {:ok, admitted} =
      Synapsis.Agent.Runtime.ToolRegistry.admit(
        [
          %{
            name: "skill",
            description: Synapsis.Tool.Skill.description(),
            parameters: Synapsis.Tool.Skill.parameters(),
            registration: registration
          }
        ],
        host_context,
        revision: 1,
        caller: "proof"
      )

    context = %{
      ctx.context
      | tools: admitted.tools
    }

    owner = self()

    Bypass.expect(ctx.bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      messages = Jason.decode!(body)["messages"]

      case Enum.find(messages, &(&1["role"] == "tool")) do
        nil ->
          sse(conn, [
            chunk(%{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "c",
                  "type" => "function",
                  "function" => %{
                    "name" => "skill",
                    "arguments" => "{\"locator\":\"proof:review\"}"
                  }
                }
              ]
            }),
            chunk(%{}, "tool_calls")
          ])

        result ->
          assert result["tool_call_id"] == "c"
          assert Jason.encode!(result["content"]) =~ "Review body"
          send(owner, :skill_result_replayed)
          sse(conn, [chunk(%{"content" => "Read the skill"}), chunk(%{}, "stop")])
      end
    end)

    caller = start_supervised!(Task.Supervisor)
    run_id = ctx.request.run_id

    options =
      Proof.options(run_id, nil,
        provider: ProviderAdapter,
        provider_context: context,
        registry: admitted.registry,
        authority: admitted.authority
      )

    pid = start_supervised!({Conversation, options})
    assert {:ok, _} = Proof.prompt(caller, pid, "Use review")
    assert_receive :skill_result_replayed, 3_000
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000

    assert Enum.map(Conversation.status(pid).messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :assistant
           ]
  end

  test "a missing HTTP terminal never becomes a successful response", ctx do
    Bypass.expect_once(ctx.bypass, fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        "data: " <> Jason.encode!(chunk(%{"content" => "partial"})) <> "\n\n"
      )
    end)

    events = Enum.to_list(ProviderAdapter.stream(ctx.request, ctx.context))
    assert List.last(events).type == :response_failed
    refute Enum.any?(events, &(&1.type == :response_completed))
  end

  test "malformed history fails before an HTTP request", ctx do
    request = %{ctx.request | messages: [%{role: :user, content: [%{type: :audio}]}]}

    assert [%{type: :response_failed}] =
             Enum.to_list(ProviderAdapter.stream(request, ctx.context))
  end

  test "invalid deadline fails once rather than producing an unbounded error stream", ctx do
    assert [%{type: :response_failed}] =
             Enum.to_list(
               ProviderAdapter.stream(
                 ctx.request,
                 %{ctx.context | stream_timeout: 0}
               )
             )
  end

  test "output limit fails explicitly", ctx do
    Bypass.expect_once(ctx.bypass, fn conn ->
      sse(conn, [chunk(%{"content" => String.duplicate("x", 100)})])
    end)

    events =
      Enum.to_list(ProviderAdapter.stream(ctx.request, Map.put(ctx.context, :output_limit, 10)))

    assert %{type: :response_failed, error: %{class: :budget_exceeded}} = List.last(events)
  end

  for mode <- [:halt, :owner_death, :timeout, :relay_death, :provider_death] do
    test "#{mode} cleans up the relay and its linked provider task", ctx do
      owner = self()

      Bypass.expect_once(ctx.bypass, fn conn ->
        # Let the fixture report its expectation after the client disconnects,
        # instead of racing Cowboy's shutdown with Bypass's handler monitor.
        Process.flag(:trap_exit, true)
        conn = Plug.Conn.send_chunked(conn, 200)
        send(owner, {:http_waiting, self()})

        receive do
          :release -> conn
        after
          4_000 -> conn
        end
      end)

      baseline = Task.Supervisor.children(Synapsis.Provider.TaskSupervisor)
      supervisor = start_supervised!(Task.Supervisor)

      context =
        if unquote(mode) == :timeout, do: %{ctx.context | stream_timeout: 500}, else: ctx.context

      consumer =
        Task.Supervisor.async_nolink(supervisor, fn ->
          stream = ProviderAdapter.stream(ctx.request, context)

          Enum.reduce_while(stream, [], fn event, acc ->
            if unquote(mode) == :halt and event.type == :response_started do
              send(owner, {:consumer_ready, self()})

              receive do
                :halt -> {:halt, [event | acc]}
              after
                3_000 -> raise "test did not release consumer"
              end
            else
              {:cont, [event | acc]}
            end
          end)
        end)

      assert_receive {:http_waiting, handler}, 2_000
      children = Task.Supervisor.children(Synapsis.Provider.TaskSupervisor) -- baseline
      assert length(children) == 2
      monitors = Enum.map(children, &{&1, Process.monitor(&1)})

      case unquote(mode) do
        :halt ->
          assert_receive {:consumer_ready, pid}, 2_000
          send(pid, :halt)
          assert {:ok, _} = Task.yield(consumer, 2_000)

        :owner_death ->
          Task.shutdown(consumer, :brutal_kill)

        mode when mode in [:relay_death, :provider_death] ->
          relay =
            Enum.find(children, fn pid ->
              case Process.info(pid, :monitors) do
                {:monitors, monitors} -> {:process, consumer.pid} in monitors
                nil -> false
              end
            end)

          assert is_pid(relay)
          victim = %{relay_death: relay, provider_death: hd(children -- [relay])}[mode]
          Process.exit(victim, :kill)

          assert {:ok, [%{type: :response_failed, error: %{class: :execution_failure}} | _]} =
                   Task.yield(consumer, 2_000)

        :timeout ->
          assert {:ok, [%{type: :response_failed, error: %{class: :timeout}} | _]} =
                   Task.yield(consumer, 2_000)
      end

      for {pid, ref} <- monitors do
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      end

      send(handler, :release)
    end
  end

  defp chunk(delta, finish \\ nil),
    do: %{
      "id" => "fixture",
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
    }

  defp sse(conn, chunks) do
    body =
      Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"

    conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.resp(200, body)
  end
end
