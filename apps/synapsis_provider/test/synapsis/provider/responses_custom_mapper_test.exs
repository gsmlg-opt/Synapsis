defmodule Synapsis.Provider.ResponsesCustomMapperTest do
  use ExUnit.Case, async: true
  alias Backplane.AiProtocol.{ContentBlock, Error, StreamEvent, ToolCall}
  alias Synapsis.Provider.{Adapter, EventMapper, MessageMapper}

  test "explicit Responses selectors stay distinct from Chat Completions" do
    assert Adapter.resolve_transport_type(:openai_responses) == :openai_responses
    assert Adapter.resolve_transport_type("openai_responses") == :openai_responses
  end

  test "typed custom, JSON and structured completion retain their original argument kind" do
    for {raw, expected} <- [
          {{:custom, " \n你好\n"}, " \n你好\n"},
          {{:json, "{\"x\":1}"}, %{"x" => 1}},
          {{:structured, %{"x" => 1}}, %{"x" => 1}}
        ] do
      call = %ToolCall{id: "c", name: "raw_probe", raw_arguments: raw}

      event = %StreamEvent{
        type: :tool_call_done,
        index: 0,
        call_id: "c",
        name: "raw_probe",
        content: %ContentBlock{type: :tool_call, tool_call: call}
      }

      assert {:tool_call_done, 0, "c", "raw_probe", ^expected} = EventMapper.map_event(event)

      assert {:tool_call_done, 0, "c", "raw_probe", ^expected} =
               EventMapper.map_event(%{event | content: call})

      assert {:error, %Error{}} = EventMapper.map_event(%{event | call_id: "changed"})
      assert {:error, %Error{}} = EventMapper.map_event(%{event | name: "changed"})
    end
  end

  test "malformed typed completion is an error rather than empty input" do
    for raw <- [{:json, "[]"}, {:json, "{"}, {:custom, <<255>>}, {:structured, "bad"}] do
      call = %ToolCall{id: "c", name: "raw_probe", raw_arguments: raw}

      assert {:error, %Error{}} =
               EventMapper.map_event(%StreamEvent{
                 type: :tool_call_done,
                 index: 0,
                 call_id: "c",
                 name: "raw_probe",
                 content: %ContentBlock{type: :tool_call, tool_call: call}
               })
    end
  end

  test "a function named raw_probe still uses JSON function arguments" do
    message = %{
      role: :assistant,
      parts: [%Synapsis.Part.ToolUse{tool: "raw_probe", tool_use_id: "c", input: %{"x" => 1}}]
    }

    assert {:ok, wire} =
             MessageMapper.build_request(:openai_responses, [message], [], %{model: "probe"})

    assert [%{"type" => "function_call", "arguments" => "{\"x\":1}"}] = wire["input"]
  end

  test "Responses uses OpenAI model discovery with bearer auth at root and v1 bases" do
    for selector <- [:openai_responses, "openai_responses"], suffix <- ["", "/v1"] do
      fixture = Gaoxy.Test.open()

      Gaoxy.Test.expect_once(fixture, "GET", "/v1/models", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [%{"id" => "probe"}]}))
      end)

      assert {:ok, [%{id: "probe"}]} =
               Adapter.models(%{
                 type: selector,
                 api_key: "fixture",
                 base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/") <> suffix
               })
    end
  end

  test "protocols without custom tools omit them instead of failing the request" do
    patch = %{
      type: :custom,
      name: "apply_patch",
      description: "Freeform patch",
      format: %{"type" => "grammar", "syntax" => "lark", "definition" => "start: /.+/"}
    }

    read = %{
      name: "synapsis::read",
      description: "Read a file",
      parameters: %{"type" => "object", "properties" => %{}}
    }

    message = %{role: :user, parts: [%Synapsis.Part.Text{content: "hi"}]}

    for protocol <- [:anthropic, :openai, :google] do
      assert {:ok, wire} =
               MessageMapper.build_request(protocol, [message], [patch, read], %{model: "m"})

      encoded = Jason.encode!(wire)
      refute encoded =~ "apply_patch"
      assert encoded =~ Synapsis.Provider.ToolName.encode("synapsis::read")
    end

    assert {:ok, wire} =
             MessageMapper.build_request(:openai_responses, [message], [patch, read], %{
               model: "m"
             })

    assert Jason.encode!(wire) =~ "apply_patch"
  end

end
