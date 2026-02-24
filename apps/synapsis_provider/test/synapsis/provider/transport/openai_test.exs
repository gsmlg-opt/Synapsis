defmodule Synapsis.Provider.Transport.OpenAITest do
  use ExUnit.Case

  alias Synapsis.Provider.Transport.OpenAI

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, port: bypass.port}
  end

  describe "fetch_models/1" do
    test "returns parsed models on success", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "gpt-4o", "context_length" => 128_000},
              %{"id" => "gpt-4o-mini", "context_length" => 128_000},
              %{"id" => "gpt-3.5-turbo"}
            ]
          })
        )
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}"}
      assert {:ok, models} = OpenAI.fetch_models(config)
      assert length(models) == 3

      gpt4o = Enum.find(models, &(&1.id == "gpt-4o"))
      assert gpt4o.name == "gpt-4o"
      assert gpt4o.context_window == 128_000

      # Model without context_length defaults to 128_000
      turbo = Enum.find(models, &(&1.id == "gpt-3.5-turbo"))
      assert turbo.context_window == 128_000
    end

    test "sends Authorization header with api_key", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        headers = Map.new(conn.req_headers)
        assert headers["authorization"] == "Bearer my-secret-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => []}))
      end)

      config = %{api_key: "my-secret-key", base_url: "http://localhost:#{port}"}
      assert {:ok, []} = OpenAI.fetch_models(config)
    end

    test "returns error on non-200 status", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
      end)

      config = %{api_key: "bad-key", base_url: "http://localhost:#{port}"}
      assert {:error, "HTTP 401"} = OpenAI.fetch_models(config)
    end

    test "returns error on connection failure" do
      config = %{api_key: "test-key", base_url: "http://localhost:1"}
      assert {:error, _reason} = OpenAI.fetch_models(config)
    end

    test "works without api_key for local models", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        headers = Map.new(conn.req_headers)
        refute Map.has_key?(headers, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"id" => "llama3"}]})
        )
      end)

      config = %{base_url: "http://localhost:#{port}"}
      assert {:ok, [model]} = OpenAI.fetch_models(config)
      assert model.id == "llama3"
    end
  end

  describe "default_base_url/0" do
    test "returns OpenAI URL" do
      assert OpenAI.default_base_url() == "https://api.openai.com"
    end
  end

  describe "stream/3" do
    test "sends chunks to caller", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"id":"1","choices":[{"delta":{"content":"Hi"}}]}

        data: [DONE]

        """)
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}"}
      request = %{model: "gpt-4o", messages: [], stream: true}

      caller = self()

      Task.start(fn ->
        OpenAI.stream(request, config, caller)
      end)

      assert_receive {:chunk, %{"id" => "1"}}, 5000
      assert_receive {:chunk, "[DONE]"}, 5000
      assert_receive :stream_done, 5000
    end

    test "sends stream_error on connection failure" do
      config = %{api_key: "test-key", base_url: "http://localhost:1"}
      request = %{model: "gpt-4o", messages: [], stream: true}

      caller = self()

      Task.start(fn ->
        OpenAI.stream(request, config, caller)
      end)

      assert_receive {:stream_error, _reason}, 10_000
    end

    test "Azure URL construction uses deployment name", %{bypass: bypass, port: port} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/openai/deployments/my-model/chat/completions",
        fn conn ->
          assert conn.query_string =~ "api-version="

          headers = Map.new(conn.req_headers)
          assert headers["api-key"] == "azure-key"

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          parsed = Jason.decode!(body)
          refute Map.has_key?(parsed, "model")

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, """
          data: {"id":"1","choices":[{"delta":{"content":"OK"}}]}

          data: [DONE]

          """)
        end
      )

      config = %{
        api_key: "azure-key",
        base_url: "http://localhost:#{port}",
        azure: true,
        api_version: "2024-06-01"
      }

      request = %{model: "my-model", messages: [], stream: true}
      caller = self()

      Task.start(fn ->
        OpenAI.stream(request, config, caller)
      end)

      assert_receive {:chunk, _}, 5000
      assert_receive :stream_done, 5000
    end
  end
end
