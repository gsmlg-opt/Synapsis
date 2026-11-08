defmodule Synapsis.SessionHistoryTest do
  use ExUnit.Case, async: false
  alias Synapsis.Session.Store
  alias Synapsis.SessionHistory

  setup do
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, agent: "history-reader"})
    on_exit(fn -> Store.delete_session(id) end)
    %{id: id, context: %{session_id: id, agent_id: "history-reader"}}
  end

  test "sparse durable pages preserve exact text and exclusive indexes", ctx do
    for {index, role, text} <- [
          {0, "user", "Hello\n世界"},
          {7, "assistant", "  exact reply  "},
          {91, "user", "Next"}
        ] do
      put(ctx.id, index, role, [%{type: "text", text: text}])
    end

    assert {:ok, page} = SessionHistory.read(%{"limit" => 2}, ctx.context)
    assert page.source == "durable"
    assert page.session_id == ctx.id
    assert page.has_more and page.next_cursor == 7 and page.truncated == false

    assert Enum.map(page.turns, &{&1.index, &1.role, &1.parts}) == [
             {0, "user", [%{type: "text", text: "Hello\n世界"}]},
             {7, "assistant", [%{type: "text", text: "  exact reply  "}]}
           ]

    assert {:ok, %{turns: [%{index: 91}], has_more: false, next_cursor: nil}} =
             SessionHistory.read(%{"cursor" => page.next_cursor}, ctx.context)
  end

  test "existing empty target and explicit persisted target are readable", ctx do
    target = Ecto.UUID.generate()
    :ok = Store.put_meta(target, %{id: target, agent: "another-agent"})
    on_exit(fn -> Store.delete_session(target) end)

    assert {:ok, %{session_id: ^target, turns: [], has_more: false, next_cursor: nil}} =
             SessionHistory.read(%{"session_id" => target}, ctx.context)
  end

  test "tool calls remain visible by default and public tool replies are optional",
       ctx do
    projection = %{
      "version" => 1,
      "result" => %{"content" => "Done", "is_error" => false, "structured" => %{"count" => 2}}
    }

    put(ctx.id, 1, "assistant", [
      %{type: "tool_use", id: "call-1", name: "example", input: %{"count" => 2}},
      %{
        type: "tool_result",
        tool_use_id: "call-1",
        content: "Done",
        is_error: false,
        projection: projection
      }
    ])

    assert {:ok, %{turns: [%{parts: [default_call], omitted_tool_parts: 1}]}} =
             SessionHistory.read(%{}, ctx.context)

    assert {:ok, %{turns: [%{parts: [call, result], omitted_tool_parts: 0}]}} =
             SessionHistory.read(%{"include_tools" => true}, ctx.context)

    assert default_call == call
    assert call == %{type: "tool_use", id: "call-1", name: "example", input: %{"count" => 2}}
    assert result.content == "Done" and result.projection == projection
  end

  test "rich tool results describe nested images while retaining ordinary structured values",
       ctx do
    image = %{
      "type" => "image",
      "data" => %{"source" => "base64", "media_type" => "image/png", "data" => "aW1hZ2U="}
    }

    arguments = %{"config" => %{"format" => "png"}, "signature" => "Reviewed chart"}

    projection = %{
      "version" => 1,
      "result" => %{
        "content" => [%{"type" => "text", "text" => "Rendered chart"}, image],
        "is_error" => false,
        "structured" => %{"config" => %{"format" => "png"}, "preview" => image}
      }
    }

    put(ctx.id, 0, "assistant", [
      %{type: "tool_use", id: "chart-1", name: "render_chart", input: arguments},
      %{
        type: "tool_result",
        tool_use_id: "chart-1",
        content: "Rendered chart",
        is_error: false,
        projection: projection
      }
    ])

    assert {:ok, %{turns: [%{parts: [call, result]}]}} =
             SessionHistory.read(%{"include_tools" => true}, ctx.context)

    assert call.input == arguments
    assert result.content == "Rendered chart"
    public = result.projection["result"]
    assert [%{"type" => "text", "text" => "Rendered chart"}, summary] = public["content"]

    assert summary == %{
             "type" => "image",
             "omitted" => true,
             "reason" => "media_not_included",
             "media_type" => "image/png"
           }

    assert public["structured"] == %{"config" => %{"format" => "png"}, "preview" => summary}
  end

  test "media file reasoning and unsupported parts have explicit typed omissions", ctx do
    put(ctx.id, 0, "assistant", [
      %{type: "image", media_type: "image/png", path: "chart.png", data: "body"},
      %{type: "file", path: "report.txt", content: "report"},
      %{type: "reasoning", content: "reasoning"},
      %{type: "future_part"}
    ])

    assert {:ok, %{turns: [%{parts: parts}]}} = SessionHistory.read(%{}, ctx.context)

    assert Enum.map(parts, &{&1.type, &1.omitted}) == [
             {"image", true},
             {"file", true},
             {"reasoning", true},
             {"future_part", true}
           ]

    assert Enum.at(parts, 0).media_type == "image/png"
    assert Enum.at(parts, 1).path == "report.txt"
    assert Enum.at(parts, 3).reason == "unsupported_part"
  end

  defp put(id, index, role, parts) do
    assert :ok =
             Store.commit_turn(id, index, %{role: role, parts: parts}, %{
               id: id,
               agent: "history-reader"
             })
  end
end
