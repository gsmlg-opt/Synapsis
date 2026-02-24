defmodule Synapsis.Provider.Transport.GoogleTest do
  use ExUnit.Case

  alias Synapsis.Provider.Transport.Google

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, port: bypass.port}
  end

  describe "stream/3" do
    test "sends API key in URL query parameter", %{bypass: bypass, port: port} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/v1beta/models/gemini-2.0-flash:streamGenerateContent",
        fn conn ->
          assert conn.query_string =~ "key=test-google-key"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, """
          data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}

          data: {"candidates":[{"finishReason":"STOP"}]}

          """)
        end
      )

      config = %{api_key: "test-google-key", base_url: "http://localhost:#{port}"}
      request = %{model: "gemini-2.0-flash", contents: [], stream: true}
      caller = self()

      Task.start(fn -> Google.stream(request, config, caller) end)

      assert_receive {:chunk, _}, 5000
      assert_receive :stream_done, 5000
    end

    test "strips model and stream from request body", %{bypass: bypass, port: port} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/v1beta/models/gemini-2.0-flash:streamGenerateContent",
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          parsed = Jason.decode!(body)
          refute Map.has_key?(parsed, "model")
          refute Map.has_key?(parsed, "stream")
          assert Map.has_key?(parsed, "contents")

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n")
        end
      )

      config = %{api_key: "key", base_url: "http://localhost:#{port}"}
      request = %{model: "gemini-2.0-flash", contents: [%{role: "user", parts: [%{text: "Hi"}]}], stream: true}
      caller = self()

      Task.start(fn -> Google.stream(request, config, caller) end)

      assert_receive :stream_done, 5000
    end

    test "sends stream_error on failure" do
      config = %{api_key: "key", base_url: "http://localhost:1"}
      request = %{model: "gemini-2.0-flash", contents: [], stream: true}
      caller = self()

      Task.start(fn -> Google.stream(request, config, caller) end)

      assert_receive {:stream_error, _reason}, 10_000
    end
  end

  describe "default_base_url/0" do
    test "returns Google API URL" do
      assert Google.default_base_url() == "https://generativelanguage.googleapis.com"
    end
  end
end
