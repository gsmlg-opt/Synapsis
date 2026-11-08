defmodule SynapsisCli.ToolResultTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  test "oneshot displays projected text and image summaries in content order" do
    output =
      render(
        projected(%{
          "content" => [
            %{"type" => "text", "text" => "before-image"},
            %{
              "type" => "image",
              "data" => %{
                "source" => "base64",
                "media_type" => "image/png",
                "data" => "cHJpdmF0ZS1pbWFnZS1ieXRlcw=="
              }
            },
            %{"type" => "text", "text" => "after-image"}
          ]
        })
      )

    assert output =~ ~r/before-image.*\[image: image\/png; source: base64\].*after-image/s
    refute output =~ "cHJpdmF0ZS1pbWFnZS1ieXRlcw=="
    refute output =~ "legacy-success"
    assert output =~ IO.ANSI.green()
  end

  test "oneshot labels public structured result sidecars without absent placeholders" do
    output =
      render(
        projected(%{
          "content" => "public-text",
          "structured" => %{"rows" => [3]},
          "artifacts" => [%{"uri" => "workspace://report"}],
          "details" => %{"count" => 1},
          "progress" => %{"status" => "running"},
          "pagination" => %{"cursor" => "page-2", "truncated" => true}
        })
      )

    assert output =~ "public-text"
    assert output =~ ~s(Structured: {"rows":[3]})
    assert output =~ ~s(Artifacts: [{"uri":"workspace://report"}])
    assert output =~ ~s(Details: {"count":1})
    assert output =~ ~s(Progress: {"status":"running"})
    assert output =~ "Pagination: "
    assert output =~ ~s("cursor":"page-2")
    assert output =~ ~s("truncated":true)

    text_only = render(projected(%{"content" => "only-text"}))
    assert text_only =~ "only-text"
    refute text_only =~ ~r/Structured:|Artifacts:|Details:|Progress:|Pagination:|Error class:/
  end

  test "oneshot displays projected native error class message and details in red" do
    output =
      render(
        projected(
          %{
            "is_error" => true,
            "error" => %{
              "class" => "forbidden",
              "message" => "Tool denied by capability policy",
              "details" => %{"retryable" => false}
            }
          },
          true
        )
      )

    assert output =~ IO.ANSI.red()
    assert output =~ "Error class: forbidden"
    assert output =~ "Error message: Tool denied by capability policy"
    assert output =~ ~s(Error details: {"retryable":false})
    refute output =~ "legacy-success"
    refute output =~ "Structured:"
  end

  test "oneshot marks unsupported content and never fetches references or prints embedded bytes" do
    fixture = Gaoxy.Test.open()
    owner = self()

    Gaoxy.Test.stub(fixture, "GET", "/media", fn conn ->
      send(owner, :media_fetched)
      Plug.Conn.resp(conn, 200, "unexpected media fetch")
    end)

    uri = Gaoxy.Test.url(fixture, "/media")

    output =
      render(
        projected(%{
          "content" => [
            %{
              "type" => "image",
              "data" => %{"source" => "url", "media_type" => "image/jpeg", "url" => uri}
            },
            %{"type" => "audio", "data" => "ZW1iZWRkZWQtYXVkaW8="},
            %{
              "type" => "resource",
              "resource" => %{"uri" => uri, "blob" => "ZW1iZWRkZWQtYmxvYg=="}
            },
            %{"type" => "resource_link", "uri" => uri},
            %{"type" => "future_media", "data" => "embedded-future-bytes"}
          ]
        })
      )

    assert output =~ "[image: image/jpeg; source: url]"

    for type <- ~w(audio resource resource_link future_media) do
      assert output =~ "[unsupported content: #{type}]"
    end

    refute output =~ "ZW1iZWRkZWQt"
    refute output =~ "embedded-future-bytes"
    refute_receive :media_fetched
  end

  test "oneshot summarizes retained MCP images and labels opaque object content" do
    output =
      render(
        projected(%{
          "content" => [
            %{"type" => "image", "data" => "bWNwLWltYWdlLWJ5dGVz", "mimeType" => "image/png"}
          ]
        })
      )

    assert output =~ "[image: image/png; source: base64]"
    refute output =~ "bWNwLWltYWdlLWJ5dGVz"

    opaque = render(projected(%{"content" => %{"blob" => "opaque-embedded-bytes"}}))
    assert opaque =~ "[unsupported content: object]"
    refute opaque =~ "opaque-embedded-bytes"
    refute opaque =~ "invalid projection"
  end

  test "oneshot reports invalid projection versions shapes and mismatched error state explicitly" do
    invalid = [
      %{"version" => 2, "result" => %{"is_error" => false}},
      %{"version" => 1.0, "result" => %{"is_error" => false}},
      %{"version" => 1, "result" => []},
      %{"version" => 1, "result" => %{}},
      %{"version" => 1, "result" => %{"is_error" => "false"}},
      %{"version" => 1, "result" => %{"is_error" => true}},
      %{"version" => 1, "result" => %{"is_error" => false}, "extra" => true},
      %{"version" => 1, "result" => %{"is_error" => false, "content" => 42}},
      %{
        "version" => 1,
        "result" => %{"is_error" => false, "content" => [%{"type" => "text", "text" => 42}]}
      },
      %{
        "version" => 1,
        "result" => %{
          "is_error" => false,
          "content" => [%{"type" => "image", "data" => "invalid"}]
        }
      },
      %{"version" => 1, "result" => %{"is_error" => false, "error" => "invalid"}},
      "not-an-envelope"
    ]

    for projection <- invalid do
      output =
        render(%{"content" => "legacy-success", "is_error" => false, "projection" => projection})

      assert output =~ "Tool result display error: invalid projection"
      assert output =~ IO.ANSI.red()
      refute output =~ "legacy-success"
    end

    for outer <- ["false", nil] do
      output =
        render(%{
          "content" => "legacy-success",
          "is_error" => outer,
          "projection" => projected(%{})["projection"]
        })

      assert output =~ "Tool result display error: invalid projection"
      refute output =~ "legacy-success"
    end
  end

  test "nil and absent projections preserve legacy text color and silent 500 character truncation" do
    content = String.duplicate("x", 500) <> "hidden-tail"

    for is_error <- [false, true], projection <- [:absent, nil] do
      event = %{"content" => content, "is_error" => is_error}
      event = if projection == :absent, do: event, else: Map.put(event, "projection", projection)
      color = if is_error, do: IO.ANSI.red(), else: IO.ANSI.green()

      assert render(event) == color <> String.duplicate("x", 500) <> IO.ANSI.reset() <> "\n\n"
    end
  end

  test "projected display has a visible truncation marker within the 500 character preview" do
    output = render(projected(%{"content" => String.duplicate("x", 600) <> "hidden-tail"}))
    plain = Regex.replace(~r/\e\[[0-9;]*m/, output, "") |> String.trim_trailing()

    assert plain =~ "[truncated]"
    assert String.length(plain) <= 500
    assert String.starts_with?(plain, String.duplicate("x", 100))
    refute plain =~ "hidden-tail"
  end

  defp projected(result, is_error \\ false) do
    %{
      "content" => "legacy-success",
      "is_error" => is_error,
      "projection" => %{"version" => 1, "result" => Map.put_new(result, "is_error", is_error)}
    }
  end

  defp render(event) do
    fixture = Gaoxy.Test.open()
    host = String.trim_trailing(Gaoxy.Test.url(fixture), "/")
    session_id = "cli-projection-#{System.unique_integer([:positive])}"

    Gaoxy.Test.expect_once(fixture, "POST", "/api/sessions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => session_id}}))
    end)

    Gaoxy.Test.expect_once(fixture, "POST", "/api/sessions/#{session_id}/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true}))
    end)

    Gaoxy.Test.expect_once(fixture, "GET", "/api/sessions/#{session_id}/events", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        "event: tool_result\ndata: #{Jason.encode!(event)}\n\nevent: done\ndata: \n\n"
      )
    end)

    capture_io(fn ->
      assert :ok = SynapsisCli.Main.run(["--prompt", "fixture only", "--host", host])
    end)
  end
end
