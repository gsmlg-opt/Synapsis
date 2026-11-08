defmodule Synapsis.Agent.Runtime.ResponsesCustomTransportTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Runtime.{ProviderAdapter, ProviderMessages}
  alias Synapsis.Part.ToolUse
  alias Synapsis.Session.Store

  @format %{"type" => "grammar", "syntax" => "lark", "definition" => "start: /[\\s\\S]*/"}
  @tool %{
    type: :custom,
    name: "raw_probe",
    description: "Generic raw input probe",
    format: @format
  }

  for selector <- [:openai_responses, "openai_responses"], suffix <- ["", "/v1"] do
    test "#{inspect(selector)} at base #{inspect(suffix)} preserves raw input through HTTP and Concord" do
      owner = self()
      selector = unquote(selector)
      suffix = unquote(suffix)

      for raw <- ["", " \t\n", "\n你好\n  raw bytes\n"] do
        fixture = Gaoxy.Test.open()
        context = context(fixture, selector, suffix)

        item = %{
          "type" => "custom_tool_call",
          "id" => "item-1",
          "call_id" => "call-1",
          "name" => "raw_probe",
          "input" => raw
        }

        Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture"]
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          wire = Jason.decode!(body)
          send(owner, {:declaration, wire})

          sse(conn, [
            %{
              "type" => "response.output_item.added",
              "output_index" => 0,
              "item" => Map.put(item, "input", "")
            },
            %{
              "type" => "response.custom_tool_call_input.delta",
              "item_id" => "item-1",
              "delta" => raw
            },
            %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
            completed([item])
          ])
        end)

        request = request([@tool])
        events = ProviderAdapter.stream(request, context) |> Enum.to_list()
        assert_receive {:declaration, wire}
        assert [%{"type" => "custom", "name" => "raw_probe", "format" => @format}] = wire["tools"]
        assert wire["max_output_tokens"] == 321
        refute Map.has_key?(wire, "max_tokens")

        assert %{
                 type: :tool_call_completed,
                 tool_call: %{id: "call-1", name: "raw_probe", arguments: raw}
               } in events

        assert %{type: :response_completed, message: message} = List.last(events)

        assert {:ok, [%{parts: [%ToolUse{input: ^raw} = part]}]} =
                 ProviderMessages.to_host([message])

        assert {:ok, dumped} = Synapsis.Part.dump(part)
        id = "custom-probe-" <> Ecto.UUID.generate()
        assert :ok = Store.ensure_started()
        on_exit(fn -> Store.delete_session(id) end)
        assert :ok = Store.commit_turn(id, 0, %{part: dumped}, %{latest_turn: 0})
        assert {:ok, %{part: persisted}} = Store.get_turn(id, 0)
        assert {:ok, %ToolUse{input: ^raw} = loaded} = Synapsis.Part.load(persisted)

        assert {:ok, [replay]} =
                 ProviderMessages.from_host([%{role: :assistant, parts: [loaded]}])

        replay_fixture = Gaoxy.Test.open()

        Gaoxy.Test.expect_once(replay_fixture, "POST", "/v1/responses", fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture"]
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:replay, Jason.decode!(body)})
          sse(conn, [%{"type" => "response.output_text.delta", "delta" => "done"}, completed([])])
        end)

        messages =
          request.messages ++
            [replay, %{role: :tool, tool_call_id: "call-1", result: %{content: "exact result"}}]

        assert %{type: :response_completed} =
                 ProviderAdapter.stream(
                   %{request | messages: messages},
                   context(replay_fixture, selector, suffix)
                 )
                 |> Enum.to_list()
                 |> List.last()

        assert_receive {:replay, second}

        assert %{
                 "type" => "custom_tool_call",
                 "call_id" => "call-1",
                 "name" => "raw_probe",
                 "input" => raw
               } in second["input"]

        assert %{
                 "type" => "custom_tool_call_output",
                 "call_id" => "call-1",
                 "output" => "exact result"
               } in second["input"]
      end
    end
  end

  test "custom declarations and replay reject unsupported protocols before HTTP, including an empty catalog" do
    fixture = Gaoxy.Test.open()
    owner = self()

    for path <- [
          "/v1/chat/completions",
          "/v1/messages",
          "/v1beta/models/probe:streamGenerateContent"
        ] do
      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        send(owner, :unexpected_http)
        Plug.Conn.resp(conn, 500, "unexpected")
      end)
    end

    replay = %{
      role: :assistant,
      content: [%{type: :tool_call, id: "c", name: "raw_probe", arguments: "raw"}]
    }

    for protocol <- [:openai, :anthropic, :google],
        {tools, history} <- [{[@tool], []}, {[], [replay]}] do
      request = %{request(tools) | messages: [%{role: :user, content: "probe"}] ++ history}

      assert [
               %{
                 type: :response_failed,
                 error: %Backplane.AiProtocol.Error{
                   kind: :incompatible,
                   upstream_outcome: :not_submitted,
                   compatibility: %{"capability" => "custom_tools"}
                 }
               }
             ] = ProviderAdapter.stream(request, context(fixture, protocol)) |> Enum.to_list()
    end

    refute_receive :unexpected_http
  end

  test "invalid custom declarations preserve uniqueness and resolver fences before HTTP" do
    fixture = Gaoxy.Test.open()
    owner = self()

    Gaoxy.Test.stub(fixture, "POST", "/v1/responses", fn conn ->
      send(owner, :unexpected_http)
      Plug.Conn.resp(conn, 500, "unexpected")
    end)

    for tools <- [
          [@tool, @tool],
          [Map.put(@tool, :parameters, %{})],
          [Map.put(@tool, :format, "bad")],
          [Map.put(@tool, :type, :hosted)],
          [Map.put(@tool, :name, "")]
        ] do
      assert [%{type: :response_failed}] =
               ProviderAdapter.stream(request(tools), context(fixture, :openai_responses))
               |> Enum.to_list()
    end

    denied = Backplane.AgentRuntime.Error.new(:forbidden, "Stale catalog")

    context =
      Map.put(context(fixture, :openai_responses), :tool_context_resolver, fn _ ->
        {:error, denied}
      end)

    assert [%{type: :response_failed, error: ^denied}] =
             ProviderAdapter.stream(request([@tool]), context) |> Enum.to_list()

    refute_receive :unexpected_http
  end

  test "Responses malformed and duplicate output identities fail without a successful terminal" do
    owner = self()

    item = %{
      "type" => "custom_tool_call",
      "id" => "i",
      "call_id" => "c",
      "name" => "raw_probe",
      "input" => ""
    }

    start = %{"type" => "response.output_item.added", "output_index" => 0, "item" => item}

    for events <- [
          [start, start],
          [
            start,
            %{"type" => "response.output_item.done", "item" => %{item | "name" => "changed"}}
          ],
          [
            %{
              "type" => "response.custom_tool_call_input.delta",
              "item_id" => "unknown",
              "delta" => "x"
            }
          ]
        ] do
      fixture = Gaoxy.Test.open()

      Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
        send(owner, :malformed_http_observed)
        sse(conn, events)
      end)

      events =
        ProviderAdapter.stream(request([@tool]), context(fixture, :openai_responses))
        |> Enum.to_list()

      assert_receive :malformed_http_observed
      assert %{type: :response_failed} = List.last(events)
      refute Enum.any?(events, &(&1.type == :response_completed))
    end
  end

  for mode <- [:completion, :initial] do
    test "stream guard rejects forbidden custom input supplied through #{mode}" do
      fixture = Gaoxy.Test.open()
      owner = self()

      Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
        send(owner, :guard_http_observed)
        sse(conn, custom_stream(unquote(mode), "secret"))
      end)

      context = guarded_context(fixture, ["secret"])
      events = ProviderAdapter.stream(request([@tool]), context) |> Enum.to_list()
      assert_receive :guard_http_observed

      assert %{type: :response_failed, error: {:stream_violation, redacted}} = List.last(events)
      assert redacted == "[redacted 6-byte pattern]"
      refute inspect(List.last(events)) =~ "secret"
      refute Enum.any?(events, &(&1.type == :tool_call_completed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end
  end

  test "stream guard preserves safe custom bytes and emits one completion without rescanning delta prefixes" do
    for {mode, raw, rules} <- [
          {:initial, "\n你好\n safe input\n", ["secret"]},
          {:completion, " \t\n", ["secret"]},
          {:delta, "sec", ["csec"]}
        ] do
      fixture = Gaoxy.Test.open()
      owner = self()

      Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
        send(owner, :safe_guard_http_observed)
        sse(conn, custom_stream(mode, raw))
      end)

      events =
        ProviderAdapter.stream(request([@tool]), guarded_context(fixture, rules))
        |> Enum.to_list()

      assert_receive :safe_guard_http_observed

      assert [%{tool_call: %{arguments: ^raw}}] =
               Enum.filter(events, &(&1.type == :tool_call_completed))

      assert %{type: :response_completed, message: %{content: [%{arguments: ^raw}]}} =
               List.last(events)

      refute Enum.any?(events, &(&1.type == :response_failed))

      if mode == :delta do
        assert events
               |> Enum.filter(&(&1.type == :tool_call_arguments_delta))
               |> Enum.map_join(& &1.delta) == raw
      end
    end
  end

  defp guarded_context(fixture, rules) do
    context = context(fixture, :openai_responses)
    %{context | provider_config: Map.put(context.provider_config, :stream_guard_rules, rules)}
  end

  defp custom_stream(mode, raw) do
    item = %{
      "type" => "custom_tool_call",
      "id" => "guard-item",
      "call_id" => "guard-call",
      "name" => "raw_probe",
      "input" => raw
    }

    start = %{
      "type" => "response.output_item.added",
      "output_index" => 0,
      "item" => Map.put(item, "input", if(mode == :initial, do: raw, else: ""))
    }

    deltas =
      if mode == :delta,
        do: [
          %{
            "type" => "response.custom_tool_call_input.delta",
            "item_id" => "guard-item",
            "delta" => raw
          }
        ],
        else: []

    [start] ++
      deltas ++
      [
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        completed([item])
      ]
  end

  defp context(fixture, type, suffix \\ ""),
    do: %{
      provider_config: %{
        type: type,
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/") <> suffix,
        api_key: "fixture"
      },
      request_options: %{model: "probe", max_tokens: 321},
      stream_timeout: 2_000
    }

  defp request(tools),
    do: %{
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      turn_id: "t",
      step_id: "s",
      attempt_id: "a",
      catalog_revision: 1,
      tools: tools,
      messages: [%{role: :user, content: "Probe"}]
    }

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
