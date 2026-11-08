defmodule Synapsis.Provider.TypedToolMediaTest do
  use ExUnit.Case, async: false

  alias Backplane.AiProtocol.Error
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Adapter, MessageMapper}

  @protocols [:anthropic, :openai, :openai_responses, :google]
  @audio %{"type" => "audio", "mimeType" => "audio/wav", "data" => "UklGRg=="}
  @image %{"type" => "image", "mimeType" => "image/png", "data" => "AA=="}

  test "raw MCP inline audio reaches each native codec as primary audio" do
    for protocol <- @protocols do
      reason = if protocol in [:openai, :google], do: "message_role", else: "media_form"
      assert_native_incompatibility(protocol, [@audio], "audio", reason)
    end
  end

  test "raw MCP embedded text and blob resources retain their resource kind" do
    for body <- [%{"text" => "Report body"}, %{"blob" => "UmVwb3J0"}],
        protocol <- @protocols do
      resource = Map.merge(%{"uri" => "fixture://report", "mimeType" => "text/plain"}, body)
      block = %{"type" => "resource", "resource" => resource}
      assert_native_incompatibility(protocol, [block], "resource", "media_form")
    end
  end

  test "raw MCP URI-only resources use the native tool-role compatibility boundary" do
    block = %{
      "type" => "resource",
      "resource" => %{"uri" => "https://example.test/report", "mimeType" => "text/plain"}
    }

    for protocol <- @protocols do
      reason = if protocol == :google, do: "message_role", else: "media_form"
      assert_native_incompatibility(protocol, [block], "resource", reason)
    end
  end

  test "raw MCP named resource links preserve their native kind and optional fields" do
    block = %{
      "type" => "resource_link",
      "uri" => "fixture://report",
      "name" => "report.txt",
      "mimeType" => "text/plain",
      "title" => "Report",
      "description" => "Generated report",
      "size" => 6
    }

    for protocol <- @protocols do
      assert_native_incompatibility(protocol, [block], "resource_link", "media_form")
    end
  end

  test "canonical typed media reconstruct through native constructors and codecs" do
    blocks = [
      {"audio", %{"mime_type" => "audio/wav", "data" => "UklGRg=="}},
      {"audio", %{"mime_type" => "audio/wav", "uri" => "fixture://recording"}},
      {"resource",
       %{"uri" => "fixture://report", "mime_type" => "text/plain", "text" => "Report"}},
      {"resource",
       %{"uri" => "fixture://report", "mime_type" => "text/plain", "data" => "UmVwb3J0"}},
      {"resource_link", %{"uri" => "fixture://report", "name" => "report.txt"}}
    ]

    for {type, data} <- blocks, protocol <- @protocols do
      reason =
        if type == "audio" and Map.has_key?(data, "data") and protocol in [:openai, :google],
          do: "message_role",
          else: "media_form"

      assert_native_incompatibility(protocol, [%{"type" => type, "data" => data}], type, reason)
    end
  end

  test "MCP annotations and nested resource metadata reach native media extensions" do
    metadata = %{"annotations" => %{"audience" => ["user"]}, "_meta" => %{"fixture" => "media"}}

    blocks = [
      {"audio", Map.merge(@audio, metadata)},
      {"resource",
       %{
         "type" => "resource",
         "resource" =>
           Map.merge(
             %{"uri" => "fixture://report", "mimeType" => "text/plain", "text" => "Report"},
             metadata
           )
       }},
      {"resource_link",
       Map.merge(
         %{"type" => "resource_link", "uri" => "fixture://report", "name" => "report.txt"},
         metadata
       )},
      {"audio",
       %{
         "type" => "audio",
         "data" => %{"mime_type" => "audio/wav", "data" => "UklGRg=="},
         "extensions" => %{"host::provenance" => %{"fixture" => "canonical"}}
       }}
    ]

    for {type, block} <- blocks, protocol <- @protocols do
      assert_native_incompatibility(protocol, [block], type, "media_metadata")
    end
  end

  test "ordered mixed media, call identity, status and metadata survive Part JSON dump/load" do
    resource = %{
      "type" => "resource",
      "annotations" => %{"priority" => 0.5},
      "resource" => %{
        "uri" => "fixture://report",
        "mimeType" => "text/plain",
        "text" => "Report",
        "_meta" => %{"revision" => 3}
      }
    }

    content = [
      text("before"),
      @image,
      @audio,
      resource,
      %{"type" => "resource_link", "uri" => "fixture://report", "name" => "report.txt"},
      text("after")
    ]

    for is_error <- [false, true] do
      part = projected(content, is_error)
      assert {:ok, dumped} = Synapsis.Part.dump(part)
      assert {:ok, loaded} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
      assert loaded === part
      assert loaded.projection["result"]["content"] === content
      assert_native_incompatibility(:openai, loaded, "audio", "message_role")
    end
  end

  test "legacy and projected text continue to encode across all native codecs" do
    parts = [
      %ToolResult{tool_use_id: "call", content: "legacy", is_error: true},
      projected([text("projected")])
    ]

    for protocol <- @protocols, part <- parts do
      assert {:ok, wire} = build(protocol, part)
      assert Jason.encode!(wire) =~ part.content or Jason.encode!(wire) =~ "projected"
    end
  end

  test "ordered text and image still reach an actual local Anthropic HTTP fixture" do
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

    part = projected([text("before"), @image, text("after")], true)

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
    assert result["tool_use_id"] == "call"
    assert result["is_error"]

    assert result["content"] == [
             text("before"),
             %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "AA=="}
             },
             text("after")
           ]
  end

  defp assert_native_incompatibility(protocol, content_or_part, type, reason) do
    part = if is_list(content_or_part), do: projected(content_or_part), else: content_or_part
    original = part.projection

    assert {:error,
            %Error{kind: :incompatible, stage: :translation, upstream_outcome: :not_submitted} =
              error} = build(protocol, part)

    assert error.message == "Provider cannot preserve requested media content"

    assert error.compatibility == %{
             "protocol" => Atom.to_string(protocol),
             "capability" => type,
             "reason" => reason
           }

    assert error.details == %{}
    assert part.projection === original
  end

  defp projected(content, is_error \\ false) do
    %ToolResult{
      tool_use_id: "call",
      content: "legacy-display",
      is_error: is_error,
      projection: %{"version" => 1, "result" => %{"content" => content, "is_error" => is_error}}
    }
  end

  defp text(value), do: %{"type" => "text", "text" => value}

  defp build(protocol, part),
    do: MessageMapper.build_request(protocol, messages(part), [], %{model: "test"})

  defp messages(part) do
    [
      %{role: :assistant, parts: [%ToolUse{tool_use_id: "call", tool: "fixture", input: %{}}]},
      %{role: :tool, parts: [part]}
    ]
  end
end
