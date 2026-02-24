defmodule Synapsis.Provider.Transport.AnthropicTest do
  use ExUnit.Case

  alias Synapsis.Provider.Transport.Anthropic

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, port: bypass.port}
  end

  describe "stream/3" do
    test "sends correct headers", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        headers = Map.new(conn.req_headers)
        assert headers["x-api-key"] == "test-api-key"
        assert headers["anthropic-version"] == "2023-06-01"
        assert headers["content-type"] == "application/json"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: {\"type\":\"message_stop\"}\n\n")
      end)

      config = %{api_key: "test-api-key", base_url: "http://localhost:#{port}"}
      request = %{model: "claude-sonnet-4-20250514", messages: [], stream: true}
      caller = self()

      Task.start(fn -> Anthropic.stream(request, config, caller) end)

      assert_receive {:chunk, _}, 5000
      assert_receive :stream_done, 5000
    end

    test "sends stream_error on failure" do
      config = %{api_key: "test-key", base_url: "http://localhost:1"}
      request = %{model: "claude-sonnet-4-20250514", messages: [], stream: true}
      caller = self()

      Task.start(fn -> Anthropic.stream(request, config, caller) end)

      assert_receive {:stream_error, _reason}, 10_000
    end

    test "uses custom base_url", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

        data: {"type":"message_stop"}

        """)
      end)

      config = %{api_key: "key", base_url: "http://localhost:#{port}"}
      request = %{model: "test", messages: [], stream: true}
      caller = self()

      Task.start(fn -> Anthropic.stream(request, config, caller) end)

      assert_receive {:chunk, %{"type" => "content_block_delta"}}, 5000
      assert_receive :stream_done, 5000
    end
  end

  describe "default_base_url/0" do
    test "returns Anthropic API URL" do
      assert Anthropic.default_base_url() == "https://api.anthropic.com"
    end
  end
end
