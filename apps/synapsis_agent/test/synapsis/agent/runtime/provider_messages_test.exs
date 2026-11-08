defmodule Synapsis.Agent.Runtime.ProviderMessagesTest do
  use ExUnit.Case, async: true
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Backplane.AgentRuntime.Error
  alias Synapsis.Part.{Image, Reasoning, Text, ToolResult, ToolUse}

  test "native view_image live summary preserves rich history and portable replay" do
    data = <<137, 80, 255, 0>>

    native = %{
      path: "tiny.png",
      detail: "original",
      mime_type: "image/png",
      data: data,
      bytes: byte_size(data),
      image_url: "data:image/png;base64,#{Base.encode64(data)}",
      is_error: false
    }

    assert {:ok, live} = ProviderMessages.tool_result_text(native, "view_image")
    assert live =~ "tiny.png"

    assert {:ok, [_, %{parts: [part]}] = host} =
             ProviderMessages.to_host([
               %{
                 role: :assistant,
                 content: [
                   %{
                     type: :tool_call,
                     id: "image",
                     name: "view_image",
                     arguments: %{"path" => "tiny.png"}
                   }
                 ]
               },
               %{role: :tool, tool_call_id: "image", result: native}
             ])

    assert part.content == live
    assert [_, %{"type" => "image"}] = part.projection["result"]["content"]
    assert {:ok, [_, %{result: replay}] = runtime} = ProviderMessages.from_host(host)
    refute Map.has_key?(replay, "data")
    refute Map.has_key?(replay, "image_url")
    refute Map.has_key?(replay, :data)
    refute Map.has_key?(replay, :image_url)
    assert {:ok, ^host} = ProviderMessages.to_host(runtime)

    assert {:error, %Error{class: :unsupported_capability}} =
             ProviderMessages.tool_result_text(replay)

    assert {:error, %Error{}} = ProviderMessages.tool_result_text(native)
    assert {:error, %Error{}} = ProviderMessages.tool_result_text(native, "image")

    assert {:error, %Error{}} =
             ProviderMessages.tool_result_text(%{native | bytes: 1}, "view_image")

    assert {:error, %Error{}} =
             ProviderMessages.tool_result_text(%{content: "unchecked success"}, "view_image")

    arbitrary = %{
      content: [
        %{type: :text, text: "before"},
        %{type: :image, data: %{source: "base64", media_type: "image/png", data: "AA=="}}
      ]
    }

    assert {:error, %Error{class: :unsupported_capability}} =
             ProviderMessages.tool_result_text(arbitrary)

    assert {:error, %Error{}} = ProviderMessages.tool_result_text(arbitrary, "view_image")

    for protocol <- [:openai, :google] do
      assert {:error, %Backplane.AiProtocol.Error{kind: :incompatible}} =
               Synapsis.Provider.Adapter.format_request(host, [], %{
                 model: "fixture",
                 provider_type: protocol
               })
    end
  end

  test "named historical view_image nil projections preserve legacy text and provider wire" do
    for is_error <- [false, true] do
      call = %ToolUse{tool_use_id: "old-image", tool: "view_image", input: %{"path" => "old.png"}}
      part = %ToolResult{tool_use_id: "old-image", content: "old image text", is_error: is_error}
      host = [%{role: :assistant, parts: [call]}, %{role: :tool, parts: [part]}]

      assert {:ok, runtime} = ProviderMessages.from_host(host)

      assert [%{role: :assistant}, %{role: :tool, tool_call_id: "old-image", result: legacy}] =
               runtime

      assert legacy == %{content: "old image text", is_error: is_error}
      assert {:ok, ^host} = ProviderMessages.to_host(runtime)
      assert part.projection == nil
      assert {:ok, ^part} = ProviderMessages.tool_result_part("old-image", legacy, "view_image")

      assert {:ok, wire} =
               Synapsis.Provider.Adapter.format_request(host, [], %{
                 model: "fixture",
                 provider_type: :anthropic
               })

      assert [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "old-image",
                     "name" => "view_image",
                     "input" => %{"path" => "old.png"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "old-image",
                     "is_error" => ^is_error,
                     "content" => [%{"type" => "text", "text" => "old image text"}]
                   }
                 ]
               }
             ] = wire["messages"]
    end
  end

  test "identity-aware live view_image text never accepts content-only success as a checked summary" do
    for result <- [
          %{content: "unchecked success"},
          %{content: "unchecked success", is_error: false},
          %{"content" => "unchecked success", "is_error" => false}
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               ProviderMessages.tool_result_text(result, "view_image")
    end

    assert {:ok, "public failure"} =
             ProviderMessages.tool_result_text(
               %{content: "public failure", is_error: true},
               "view_image"
             )
  end

  test "native command and clock presentations survive live text, history and provider replay" do
    for {name, result, expected} <- [
          {"exec_command",
           %{
             output: "started",
             status: :running,
             session_id: 42,
             cleanup_status: :not_started,
             termination_status: :not_requested,
             output_budget_unit: :estimated_token_bytes,
             output_truncated: false,
             omitted_output_bytes: 0,
             wall_time_seconds: 0.0
           }, "Session ID: 42"},
          {"write_stdin",
           %{
             output: "finished",
             status: :completed,
             exit_code: 0,
             cleanup_status: :confirmed,
             wall_time_seconds: 0.25
           }, "Exit code: 0"},
          {"clock::curr_time", %{current_time: "2026-10-24 12:34:56 UTC"},
           "Current time: 2026-10-24 12:34:56 UTC"},
          {"clock::sleep", %{wall_time_seconds: 0.01}, "Wall time: 0.01 seconds"}
        ] do
      assert {:ok, live} = ProviderMessages.tool_result_text(result, name)
      assert live =~ expected

      assert {:ok, [_, %{parts: [part]}] = host} =
               ProviderMessages.to_host([
                 %{
                   role: :assistant,
                   content: [%{type: :tool_call, id: "native", name: name, arguments: %{}}]
                 },
                 %{role: :tool, tool_call_id: "native", result: result}
               ])

      assert part.content == live
      assert {:ok, runtime} = ProviderMessages.from_host(host)
      assert {:ok, ^host} = ProviderMessages.to_host(runtime)

      assert {:ok, wire} =
               Synapsis.Provider.Adapter.format_request(host, [], %{
                 model: "fixture",
                 provider_type: :openai
               })

      assert List.last(wire["messages"])["content"] == live

      assert {:ok, [%{parts: [^part]}]} =
               ProviderMessages.to_host([
                 %{role: :tool, tool_call_id: "native", name: name, result: result}
               ])
    end
  end

  test "native cleanup diagnostics remain safe through live and replay presentation" do
    result = %{
      output: "partial",
      status: :cleanup_failed,
      cleanup_status: :uncertain,
      session_id: 9,
      wall_time_seconds: 0.0,
      cleanup_error:
        Error.new(:resource_conflict, "private diagnostic",
          details: %{backend_context: %{secret: "private secret"}},
          cause: self()
        )
    }

    assert {:ok, text} = ProviderMessages.tool_result_text(result, "exec_command")
    assert text =~ "Cleanup: uncertain"
    assert text =~ "Session ID: 9"

    assert {:ok, [%{parts: [part]}] = host} =
             ProviderMessages.to_host([
               %{role: :tool, tool_call_id: "command", name: "exec_command", result: result}
             ])

    assert part.content == text
    refute Jason.encode!(part.projection) =~ "private"
    refute Jason.encode!(part.projection) =~ "backend_context"
    assert {:ok, replay} = ProviderMessages.from_host(host)
    assert {:ok, ^host} = ProviderMessages.to_host(replay)
  end

  test "round trips domain history including images, signed reasoning and tool identity" do
    state = %{
      "kind" => "signed",
      "affinity" => %{"model" => "m"},
      "payload" => %{"signature" => "s"}
    }

    parts = [
      %Text{content: "hello"},
      %Image{media_type: "image/png", data: "AA==", path: "/image.png"},
      %Reasoning{content: "thought", signature: "s", provider_states: [state]},
      %ToolUse{tool_use_id: "call-1", tool: "skill", input: %{"name" => "review"}}
    ]

    messages = [
      %Synapsis.Message{role: "assistant", parts: parts},
      %Synapsis.Message{
        role: "user",
        parts: [%ToolResult{tool_use_id: "call-1", content: "body"}]
      }
    ]

    assert {:ok, runtime} = ProviderMessages.from_host(messages)
    assert [%{role: :assistant}, %{role: :tool, tool_call_id: "call-1"}] = runtime

    assert {:ok,
            [%{parts: ^parts}, %{parts: [%ToolResult{content: "body", tool_use_id: "call-1"}]}]} =
             ProviderMessages.to_host(runtime)
  end

  test "converts runtime error results to host errors without leaking inspected internals" do
    assert {:ok, [%{parts: [%ToolResult{is_error: true, content: "Tool execution failed"}]}]} =
             ProviderMessages.to_host([
               %{role: :tool, tool_call_id: "c", result: %{is_error: true, error: :denied}}
             ])
  end

  test "preserves safe denial and registration errors without exposing diagnostic internals" do
    for {error, expected} <- [
          {Error.new(:forbidden, "private message", details: %{secret: "private details"}),
           "Tool denied by capability policy"},
          {Error.new(:resource_conflict, "Tool registration changed", cause: "private cause"),
           "Tool registration changed"},
          {Error.new(:not_found, "tool is not registered", details: %{secret: "private details"}),
           "Tool denied: tool is not in this run catalog"},
          {Error.new(:not_found, "private missing tool", details: %{secret: "private details"}),
           "Tool execution failed"},
          {Error.new(:resource_conflict, "private conflict"), "Tool execution failed"},
          {Error.new(:execution_failure, "private failure", details: %{secret: "private details"}),
           "Tool execution failed"}
        ] do
      assert {:ok, ^expected} =
               ProviderMessages.tool_result_text(%{is_error: true, error: error})

      assert {:ok, [%{parts: [%ToolResult{is_error: true, content: ^expected}]}]} =
               ProviderMessages.to_host([
                 %{role: :tool, tool_call_id: "c", result: %{is_error: true, error: error}}
               ])
    end
  end

  test "rich native results round trip public structured fields and ordered content" do
    result = %{
      content: [%{type: :text, text: "memory stored"}],
      structured: %{path: "/global/memory.md", revision: 3},
      metadata: %{"future_field" => [nil, true, 4]}
    }

    assert {:ok, [%{parts: [part]}] = host} =
             ProviderMessages.to_host([%{role: :tool, tool_call_id: "memory", result: result}])

    assert part.content == "memory stored"
    assert part.projection["result"]["structured"]["revision"] == 3
    assert {:ok, [%{result: replay}] = runtime} = ProviderMessages.from_host(host)
    assert replay.content == [%{"type" => "text", "text" => "memory stored"}]
    assert replay["structured"] == %{"path" => "/global/memory.md", "revision" => 3}
    assert replay["metadata"] == %{"future_field" => [nil, true, 4]}
    assert {:ok, [%{parts: [^part]}]} = ProviderMessages.to_host(runtime)
  end

  test "historical nil projections and plain bytes keep their legacy representation" do
    part = %ToolResult{tool_use_id: "old", content: "{\"old\":true}\n", is_error: false}

    assert {:ok, [%{result: %{content: content, is_error: false}}] = runtime} =
             ProviderMessages.from_host([%{role: "tool", parts: [part]}])

    assert content == part.content
    assert {:ok, [%{parts: [^part]}]} = ProviderMessages.to_host(runtime)
  end

  test "historical plain results remain readable beyond native projection string limits" do
    content =
      String.duplicate("x", Backplane.AiProtocol.Validation.default_limits().max_string_bytes + 1)

    part = %ToolResult{tool_use_id: "old-large", content: content}

    assert {:ok, [%{result: %{content: ^content}}] = runtime} =
             ProviderMessages.from_host([%{role: "user", parts: [part]}])

    assert {:ok, [%{parts: [^part]}]} = ProviderMessages.to_host(runtime)
  end

  test "native message names present results and must match observed call identities" do
    result = %{
      role: :tool,
      tool_call_id: "spawn",
      name: "spawn_agent",
      result: %{task_name: "/root/child"}
    }

    assert {:ok, [%{parts: [%ToolResult{content: "Spawned agent /root/child"}]}]} =
             ProviderMessages.to_host([result])

    call = %{
      role: :assistant,
      content: [%{type: :tool_call, id: "spawn", name: "spawn_agent", arguments: %{}}]
    }

    assert {:ok, [_, %{parts: [%ToolResult{content: "Spawned agent /root/child"}]}]} =
             ProviderMessages.to_host([call, result])

    for name <- ["wait_agent", "", :spawn_agent, nil] do
      assert {:error, %Error{}} = ProviderMessages.to_host([call, %{result | name: name}])
    end
  end

  test "native collaboration presentation uses the exact preceding call identity" do
    calls = [
      %{id: "spawn", name: "spawn_agent", arguments: %{"message" => "work"}},
      %{id: "wait", name: "wait_agent", arguments: %{}}
    ]

    assert {:ok, [_, %{parts: [spawn]}, %{parts: [wait]}] = host} =
             ProviderMessages.to_host([
               %{role: :assistant, content: "Starting", tool_calls: calls},
               %{
                 role: :tool,
                 tool_call_id: "spawn",
                 result: %{task_name: "/root/child", nickname: nil}
               },
               %{
                 role: :tool,
                 tool_call_id: "wait",
                 result: %{message: "Wait completed.", timed_out: false}
               }
             ])

    assert spawn.content == "Spawned agent /root/child"
    assert spawn.projection["result"]["task_name"] == "/root/child"
    assert wait.content == "Wait completed."
    assert wait.projection["result"]["timed_out"] == false
    assert {:ok, replay} = ProviderMessages.from_host(host)
    assert {:ok, ^host} = ProviderMessages.to_host(replay)

    assert {:error, %Error{}} =
             ProviderMessages.to_host([
               %{role: :tool, tool_call_id: "unknown", result: %{task_name: "/root/child"}}
             ])
  end

  test "collaboration call blocks and public status enums have bounded presentations" do
    assert {:ok, [_, %{parts: [part]}]} =
             ProviderMessages.to_host([
               %{
                 role: :assistant,
                 content: [%{type: :tool_call, id: "list", name: "list_agents", arguments: %{}}]
               },
               %{
                 role: :tool,
                 tool_call_id: "list",
                 result: %{agents: [%{agent_name: "/root/child", agent_status: :running}]}
               }
             ])

    assert part.content == "/root/child: running"

    assert part.projection["result"]["agents"] ==
             [%{"agent_name" => "/root/child", "agent_status" => "running"}]
  end

  test "list_agents preserves native activation failure reasons through projection and replay" do
    for reason <- [:startup_failure, :admission_failure] do
      text = Atom.to_string(reason)
      result = %{agents: [%{agent_name: "/root/failed", agent_status: %{errored: reason}}]}

      assert {:ok, [_, %{parts: [part]}] = host} =
               ProviderMessages.to_host([
                 %{
                   role: :assistant,
                   content: [%{type: :tool_call, id: "list", name: "list_agents", arguments: %{}}]
                 },
                 %{role: :tool, tool_call_id: "list", name: "list_agents", result: result}
               ])

      assert part.content == "/root/failed: errored: " <> text

      assert part.projection["result"]["agents"] ==
               [%{"agent_name" => "/root/failed", "agent_status" => %{"errored" => text}}]

      assert {:ok, runtime} = ProviderMessages.from_host(host)
      assert {:ok, ^host} = ProviderMessages.to_host(runtime)
    end
  end

  test "completed collaboration reasoning stays projected through history and provider replay" do
    state = %{"kind" => "signed", "payload" => %{"signature" => "opaque-signed-state"}}

    blocks = [
      %{
        type: :reasoning,
        text: "private reasoning",
        signature: "signed",
        provider_states: [state]
      },
      %{type: :text, text: "First"},
      %{type: :provider_state, state: state},
      %{type: :text, text: "Second"}
    ]

    for {name, result, expected} <- [
          {"list_agents",
           %{agents: [%{agent_name: "/root/child", agent_status: %{completed: blocks}}]},
           "/root/child: completed: First\nSecond"},
          {"interrupt_agent", %{previous_status: %{completed: blocks}, status: :interrupted},
           "Agent interrupted: completed: First\nSecond -> interrupted"}
        ] do
      assert {:ok, [%{parts: [part]}] = host} =
               ProviderMessages.to_host([
                 %{role: :tool, tool_call_id: "status", name: name, result: result}
               ])

      assert part.content == expected
      assert Jason.encode!(part.projection) =~ "opaque-signed-state"
      assert {:ok, runtime} = ProviderMessages.from_host(host)
      assert {:ok, ^host} = ProviderMessages.to_host(runtime)

      assert {:ok, wire} =
               Synapsis.Provider.Adapter.format_request(host, [], %{
                 model: "fixture",
                 provider_type: :openai
               })

      assert [%{"content" => ^expected}] = wire["messages"]
      refute Jason.encode!(wire) =~ "private reasoning"
      refute Jason.encode!(wire) =~ "opaque-signed-state"
    end
  end

  test "native diagnostic errors retain safe class and text without secret details" do
    error =
      Error.new(:forbidden, "private diagnostic",
        details: %{secret: "private detail"},
        cause: self()
      )

    assert {:ok, [%{parts: [part]}]} =
             ProviderMessages.to_host([
               %{role: :tool, tool_call_id: "denied", result: %{is_error: true, error: error}}
             ])

    assert part.content == "Tool denied by capability policy"
    assert part.projection["result"]["error"]["class"] == "forbidden"
    refute Jason.encode!(part.projection) =~ "private"
    refute Map.has_key?(part.projection["result"]["error"], "cause")
  end

  test "unsupported media remains projected and provider replay rejects it explicitly" do
    result = %{content: [%{type: :text, text: "before"}, %{"type" => "audio", "data" => "YQ=="}]}

    assert {:ok, [%{parts: [part]}] = host} =
             ProviderMessages.to_host([%{role: :tool, tool_call_id: "audio", result: result}])

    assert Enum.map(part.projection["result"]["content"], & &1["type"]) == ["text", "audio"]

    assert {:error, _} =
             Synapsis.Provider.Adapter.format_request(host, [], %{
               model: "fixture",
               provider_type: :openai
             })
  end

  test "unknown contentless and nontext results have no JSON display fallback" do
    for result <- [%{unknown: "value"}, %{content: %{answer: 42}}] do
      assert {:error, %Error{}} = ProviderMessages.tool_result_text(result)

      assert {:error, %Error{}} =
               ProviderMessages.to_host([%{role: :tool, tool_call_id: "unknown", result: result}])
    end
  end

  test "unsupported history fails explicitly" do
    assert {:error, _} = ProviderMessages.to_host([%{role: :user, content: [%{type: :audio}]}])

    assert {:error, _} =
             ProviderMessages.from_host([%{role: "unknown", parts: [%Text{content: "x"}]}])

    assert {:error, _} =
             ProviderMessages.from_host([%{role: "user", parts: [%Synapsis.Part.File{}]}])
  end
end
