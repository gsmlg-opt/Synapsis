defmodule Synapsis.Provider.ResponsesToolImageFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.Adapter

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
  @call_id "responses-image-call"

  for kind <- [:function, :custom], form <- [:legacy, :mcp] do
    test "#{kind} tool output sends ordered text/image/text from #{form} projection over HTTP" do
      kind = unquote(kind)
      form = unquote(form)
      fixture = Gaoxy.Test.open()
      owner = self()

      Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(owner, {:responses_wire, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => "Image received"}]
              }
            ]
          })
        )
      end)

      result = %ToolResult{
        tool_use_id: @call_id,
        content: "Image result",
        projection: %{
          "version" => 1,
          "result" => %{
            "is_error" => false,
            "content" => [text("before"), image(form), text("after")]
          }
        }
      }

      messages = [
        %{
          role: :assistant,
          parts: [%ToolUse{tool: "inspect_image", tool_use_id: @call_id, input: input(kind)}]
        },
        %{role: :user, parts: [result]}
      ]

      assert {:ok, request} =
               Adapter.format_request(messages, [tool(kind)], %{
                 provider_type: "openai_responses",
                 model: "image-fixture"
               })

      assert {:ok, "Image received"} =
               Adapter.complete(request, %{
                 type: "openai_responses",
                 api_key: "fixture",
                 base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
               })

      assert_receive {:responses_wire, wire}, 1_000
      call_type = call_type(kind)
      assert [call, output] = wire["input"]
      assert call["type"] == call_type
      assert call["call_id"] == @call_id
      assert call["name"] == "inspect_image"

      assert_call_input(call, kind)

      assert output == %{
               "type" => call_type <> "_output",
               "call_id" => @call_id,
               "output" => [
                 %{"type" => "input_text", "text" => "before"},
                 %{
                   "type" => "input_image",
                   "image_url" => "data:image/png;base64," <> @png,
                   "detail" => "auto"
                 },
                 %{"type" => "input_text", "text" => "after"}
               ]
             }

      [_, wire_image, _] = output["output"]
      assert "data:image/png;base64," <> encoded = wire_image["image_url"]
      assert Base.decode64!(encoded) == Base.decode64!(@png)

      assert result.projection["result"]["content"] == [
               text("before"),
               image(form),
               text("after")
             ]
    end
  end

  defp text(value), do: %{"type" => "text", "text" => value}

  defp image(:legacy) do
    %{
      "type" => "image",
      "data" => %{"source" => "base64", "media_type" => "image/png", "data" => @png}
    }
  end

  defp image(:mcp), do: %{"type" => "image", "mimeType" => "image/png", "data" => @png}

  defp input(:function), do: %{"path" => "tiny.png"}
  defp input(:custom), do: "Inspect tiny.png\n"

  defp call_type(:function), do: "function_call"
  defp call_type(:custom), do: "custom_tool_call"

  defp assert_call_input(call, :custom), do: assert(call["input"] == input(:custom))

  defp assert_call_input(call, :function),
    do: assert(Jason.decode!(call["arguments"]) == input(:function))

  defp tool(:function) do
    %{
      name: "inspect_image",
      description: "Inspect a local image",
      parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
    }
  end

  defp tool(:custom),
    do: %{name: "inspect_image", description: "Inspect a local image", type: :custom}
end
