defmodule Synapsis.Provider.MessageMapperProjectionTest do
  use ExUnit.Case, async: false

  alias Backplane.AiProtocol.{Error, Validation}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Adapter, MessageMapper}

  @invalid "Invalid projected tool result"
  @unsupported "Unsupported projected tool result content"
  @image %{
    "type" => "image",
    "data" => %{"source" => "base64", "media_type" => "image/png", "data" => "AA=="}
  }

  test "nil projections preserve the exact existing text wire result" do
    part = %ToolResult{tool_use_id: "call", content: "legacy", is_error: true}
    assert {:ok, wire} = build(:anthropic, part)

    assert List.last(wire["messages"]) == %{
             "role" => "user",
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "call",
                 "is_error" => true,
                 "content" => [%{"type" => "text", "text" => "legacy"}]
               }
             ]
           }
  end

  test "ordered projected text and image use native Anthropic encoding and status" do
    part = projected([text("before"), @image, text("after")], true)
    assert {:ok, wire} = build(:anthropic, part)
    result = wire["messages"] |> List.last() |> Map.fetch!("content") |> hd()

    assert result["tool_use_id"] == "call"
    assert result["is_error"]

    assert result["content"] == [
             %{"type" => "text", "text" => "before"},
             %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => "AA=="
               }
             },
             %{"type" => "text", "text" => "after"}
           ]
  end

  test "portable nested sidecars are retained-only and never sent to the model" do
    part = projected("public")

    projection =
      put_in(part.projection, ["result", "metadata"], %{
        "authorization" => "private-sidecar",
        "nested" => [%{"backend_context" => %{"value" => 3}}]
      })

    projection = put_in(projection, ["result", "structured"], %{"answer" => 42})
    part = %{part | projection: projection}
    assert {:ok, wire} = build(:anthropic, part)
    refute Jason.encode!(wire) =~ "private-sidecar"
    refute Jason.encode!(wire) =~ "backend_context"
    refute Jason.encode!(wire) =~ "answer"
    assert part.projection == projection
  end

  test "raw MCP text and image retain metadata while encoding ordered Anthropic content" do
    image = %{
      "type" => "image",
      "data" => "AA==",
      "mimeType" => "image/png",
      "annotations" => %{"audience" => ["user"]},
      "_meta" => %{"fixture" => "retained-image"}
    }

    annotated =
      Map.merge(text("before"), %{
        "annotations" => %{"priority" => 0.5},
        "_meta" => %{"fixture" => "retained-text"}
      })

    part = projected([annotated, image, text("after")])
    original = part.projection
    assert {:ok, wire} = build(:anthropic, part)
    result = wire["messages"] |> List.last() |> Map.fetch!("content") |> hd()

    assert result["content"] == [
             %{"type" => "text", "text" => "before"},
             %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "AA=="}
             },
             %{"type" => "text", "text" => "after"}
           ]

    assert part.projection === original
    refute Jason.encode!(wire) =~ "retained-"
    refute Jason.encode!(wire) =~ "annotations"
  end

  test "malformed raw MCP images and metadata fail without discarding extra content" do
    for block <- [
          %{"type" => "image", "data" => "AA==", "mimeType" => ""},
          %{"type" => "image", "data" => "", "mimeType" => "image/png"},
          %{"type" => "image", "data" => "AA==", "mimeType" => "image/png", "text" => "extra"},
          Map.put(text("public"), "annotations", []),
          Map.put(text("public"), "_meta", "private-value")
        ] do
      assert_invalid(projected([block]))
    end
  end

  test "projected text works across the three existing provider codecs" do
    for protocol <- [:anthropic, :openai, :google] do
      assert {:ok, wire} = build(protocol, projected([text("projected")]))
      assert Jason.encode!(wire) =~ "projected"
      refute Jason.encode!(wire) =~ "legacy-must-not-be-used"
    end
  end

  test "OpenAI and Google reject image tool results through the native codec" do
    for protocol <- [:openai, :google] do
      assert {:error,
              %Error{
                kind: :incompatible,
                message: "Provider cannot preserve non-text tool result content"
              }} = build(protocol, projected([@image]))
    end
  end

  test "malformed wrappers and inconsistent status return a fixed safe error" do
    for projection <- [
          %{"version" => 2, "result" => %{"content" => "public", "is_error" => false}},
          %{"version" => 1, "result" => []},
          %{"version" => 1, "result" => %{"content" => "public", "is_error" => true}},
          %{"version" => 1, "result" => %{"content" => "public", "is_error" => "false"}},
          %{"version" => 1, "result" => %{"content" => "public"}},
          %{"version" => 1, "result" => %{}, "private-field" => "private-value"},
          %{"version" => 1, :version => 1, "result" => %{}},
          %{"version" => 1, "result" => %{"is_error" => false, :is_error => false}},
          %{
            "version" => 1,
            "result" => %{"is_error" => false, "content" => "public", :content => "other"}
          }
        ] do
      assert_invalid(%{projected("public") | projection: projection})
    end

    assert_invalid(%{projected("public") | is_error: nil})
  end

  test "native portability and budget validation includes ignored nested fields" do
    limits = Validation.default_limits()

    for value <- [
          self(),
          %URI{path: "private-value"},
          :private_value,
          <<255>>,
          ["public" | :private_value],
          String.duplicate("x", limits.max_string_bytes + 1),
          List.duplicate(nil, limits.max_list_length + 1),
          Enum.reduce(1..limits.max_depth, nil, fn _, value -> [value] end)
        ] do
      part = projected("public")
      projection = put_in(part.projection, ["result", "metadata"], %{"nested" => value})
      assert_invalid(%{part | projection: projection})
    end
  end

  test "unsupported content never becomes JSON, legacy text, or blank success" do
    for content <- [
          "",
          [],
          %{"answer" => 42},
          [%{"type" => "audio", "data" => "AA=="}],
          [%{"type" => "resource_link", "uri" => "workspace://report"}],
          [text("before"), %{"type" => "future_media"}, text("after")]
        ] do
      assert {:error, %Error{kind: :incompatible, message: @unsupported}} =
               build(:anthropic, projected(content))
    end

    part = projected("public")
    result = %{"is_error" => false, "structured" => %{"answer" => 42}}

    assert {:error, %Error{kind: :incompatible, message: @unsupported}} =
             build(:anthropic, %{part | projection: %{"version" => 1, "result" => result}})
  end

  test "malformed and ambiguous consumed blocks fail without exposing their fields" do
    for block <- [
          %{"type" => "text", "text" => 3},
          %{"type" => "text", "text" => ""},
          %{"type" => "text", "text" => "public", "data" => "private-value"},
          %{"type" => "image", "data" => %{"uri" => "private-value"}},
          Map.put(@image, :data, %{"private-value" => true}),
          Map.put(@image, "text", "private-value"),
          put_in(@image, ["data", "uri"], "private-value"),
          put_in(@image, ["data", "media_type"], nil),
          put_in(@image, ["data", "data"], ""),
          "private-value"
        ] do
      assert_invalid(projected([block]))
    end
  end

  test "formatter and actual local HTTP request deliver ordered projected Anthropic media" do
    fixture = Gaoxy.Test.open()
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:wire, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "ok"}]
        })
      )
    end)

    part =
      projected([
        Map.put(text("before"), "annotations", %{"priority" => 0.5}),
        %{"type" => "image", "data" => "AA==", "mimeType" => "image/png"},
        text("after")
      ])

    request =
      Adapter.format_request(messages(part), [], %{provider_type: "anthropic", model: "test"})

    config = %{
      type: "anthropic",
      api_key: "fixture",
      base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
    }

    assert {:ok, "ok"} = Adapter.complete(request, config)
    assert_receive {:wire, wire}
    result = wire["messages"] |> List.last() |> Map.fetch!("content") |> hd()
    assert Enum.map(result["content"], & &1["type"]) == ["text", "image", "text"]
    assert result["tool_use_id"] == "call"
  end

  test "unsupported formatter output cannot start an HTTP request" do
    fixture = Gaoxy.Test.open()
    owner = self()

    Gaoxy.Test.stub(fixture, "POST", "/v1/messages", fn conn ->
      send(owner, :unexpected_http)
      Plug.Conn.resp(conn, 500, "unexpected")
    end)

    request =
      Adapter.format_request(messages(projected([%{"type" => "audio"}])), [], %{
        provider_type: "anthropic",
        model: "test"
      })

    config = %{type: "anthropic", api_key: "fixture", base_url: Gaoxy.Test.url(fixture)}
    result = Adapter.stream(request, config)
    if match?({:ok, _}, result), do: Adapter.cancel(elem(result, 1))
    assert {:error, %Error{kind: :incompatible, message: @unsupported}} = result

    assert {:error, %Error{kind: :incompatible, message: @unsupported}} =
             Adapter.complete(request, config)

    refute_receive :unexpected_http, 30
    assert Gaoxy.Test.requests(fixture) == %{entries: [], dropped: 0, cursor: 0, truncated: false}
  end

  defp assert_invalid(part) do
    assert {:error, %Error{kind: :invalid_request, message: @invalid}} = build(:anthropic, part)
  end

  defp projected(content, is_error \\ false) do
    %ToolResult{
      tool_use_id: "call",
      content: "legacy-must-not-be-used",
      is_error: is_error,
      projection: %{"version" => 1, "result" => %{"content" => content, "is_error" => is_error}}
    }
  end

  defp text(value), do: %{"type" => "text", "text" => value}

  defp build(protocol, part),
    do: MessageMapper.build_request(protocol, messages(part), [], %{model: "test"})

  defp messages(part) do
    [
      %{role: "assistant", parts: [%ToolUse{tool_use_id: "call", tool: "tool", input: %{}}]},
      %{role: "user", parts: [part]}
    ]
  end
end
