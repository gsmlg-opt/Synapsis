defmodule Synapsis.Provider.AdapterTest do
  use ExUnit.Case

  alias Synapsis.Provider.Adapter

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, port: bypass.port}
  end

  # ---------------------------------------------------------------------------
  # stream/2 — Anthropic
  # ---------------------------------------------------------------------------

  describe "stream/2 Anthropic" do
    test "receives streaming chunks", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"message_start","message":{"id":"msg_01"}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

        data: {"type":"message_stop"}

        """)
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "anthropic"}

      request =
        Adapter.format_request([], [], %{
          model: "claude-sonnet-4-20250514",
          system_prompt: "test",
          provider_type: "anthropic"
        })

      assert {:ok, ref} = Adapter.stream(request, config)

      chunks = collect_chunks(ref)
      text_deltas = for {:text_delta, text} <- chunks, do: text
      assert "Hello" in text_deltas
      assert " world" in text_deltas
      assert :done in chunks
    end

    test "handles error response", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"type" => "authentication_error"}}))
      end)

      config = %{api_key: "bad-key", base_url: "http://localhost:#{port}", type: "anthropic"}
      request = Adapter.format_request([], [], %{model: "claude-sonnet-4-20250514", provider_type: "anthropic"})

      assert {:ok, _ref} = Adapter.stream(request, config)

      # Should receive done eventually (non-SSE response)
      assert_receive(:provider_done, 5000)
    end
  end

  # ---------------------------------------------------------------------------
  # stream/2 — OpenAI
  # ---------------------------------------------------------------------------

  describe "stream/2 OpenAI" do
    test "receives streaming chunks", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """)
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "openai"}

      request =
        Adapter.format_request([], [], %{
          model: "gpt-4o",
          provider_type: "openai"
        })

      assert {:ok, ref} = Adapter.stream(request, config)

      chunks = collect_chunks(ref)
      text_deltas = for {:text_delta, text} <- chunks, do: text
      assert "Hello" in text_deltas
      assert " there" in text_deltas
      assert :done in chunks
    end

    test "Azure OpenAI uses deployment URL and api-key header", %{bypass: bypass, port: port} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/openai/deployments/gpt-4o/chat/completions",
        fn conn ->
          headers = Map.new(conn.req_headers)
          assert headers["api-key"] == "azure-key"
          refute Map.has_key?(headers, "authorization")

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          parsed = Jason.decode!(body)
          refute Map.has_key?(parsed, "model")

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, """
          data: {"id":"1","choices":[{"index":0,"delta":{"content":"Azure response"},"finish_reason":null}]}

          data: [DONE]

          """)
        end
      )

      config = %{
        api_key: "azure-key",
        base_url: "http://localhost:#{port}",
        type: "openai",
        azure: true
      }

      request = Adapter.format_request([], [], %{model: "gpt-4o", provider_type: "openai"})
      assert {:ok, ref} = Adapter.stream(request, config)
      chunks = collect_chunks(ref)
      text_deltas = for {:text_delta, text} <- chunks, do: text
      assert "Azure response" in text_deltas
    end

    test "works without api_key for local models", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"id":"1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

        data: {"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """)
      end)

      config = %{base_url: "http://localhost:#{port}", type: "local"}

      request =
        Adapter.format_request([], [], %{
          model: "llama3",
          provider_type: "openai"
        })

      assert {:ok, ref} = Adapter.stream(request, config)
      chunks = collect_chunks(ref)
      text_deltas = for {:text_delta, text} <- chunks, do: text
      assert "Hi" in text_deltas
    end
  end

  # ---------------------------------------------------------------------------
  # stream/2 — Google
  # ---------------------------------------------------------------------------

  describe "stream/2 Google" do
    test "receives streaming chunks", %{bypass: bypass, port: port} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/v1beta/models/gemini-2.0-flash:streamGenerateContent",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, """
          data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}

          data: {"candidates":[{"content":{"parts":[{"text":" world"}],"role":"model"}}]}

          data: {"candidates":[{"finishReason":"STOP"}]}

          """)
        end
      )

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "google"}

      request =
        Adapter.format_request([], [], %{
          model: "gemini-2.0-flash",
          provider_type: "google"
        })

      assert {:ok, ref} = Adapter.stream(request, config)

      chunks = collect_chunks(ref)
      text_deltas = for {:text_delta, text} <- chunks, do: text
      assert "Hello" in text_deltas
      assert " world" in text_deltas
      assert :done in chunks
    end

    test "sends API key in header, not URL query string", %{bypass: bypass, port: port} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/v1beta/models/gemini-2.0-flash:streamGenerateContent",
        fn conn ->
          headers = Map.new(conn.req_headers)
          assert headers["x-goog-api-key"] == "secret-key"
          refute conn.query_string =~ "key="

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, """
          data: {"candidates":[{"finishReason":"STOP"}]}

          """)
        end
      )

      config = %{api_key: "secret-key", base_url: "http://localhost:#{port}", type: "google"}
      request = Adapter.format_request([], [], %{model: "gemini-2.0-flash", provider_type: "google"})

      assert {:ok, ref} = Adapter.stream(request, config)
      collect_chunks(ref)
    end
  end

  # ---------------------------------------------------------------------------
  # complete/2
  # ---------------------------------------------------------------------------

  describe "complete/2" do
    test "Anthropic synchronous completion returns text", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "The answer is 4"}]
          })
        )
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "anthropic"}

      request =
        Adapter.format_request([], [], %{
          model: "claude-sonnet-4-20250514",
          system_prompt: "test",
          provider_type: "anthropic"
        })

      # complete/2 sets stream: false on the request
      request = Map.put(request, :stream, false)

      assert {:ok, text} = Adapter.complete(request, config)
      assert text == "The answer is 4"
    end

    test "OpenAI synchronous completion returns text", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "choices" => [
              %{"message" => %{"role" => "assistant", "content" => "Hello"}}
            ]
          })
        )
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "openai"}

      request =
        Adapter.format_request([], [], %{
          model: "gpt-4o",
          provider_type: "openai"
        })

      assert {:ok, text} = Adapter.complete(request, config)
      assert text == "Hello"
    end

    test "returns error on 401 unauthorized", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{"error" => %{"message" => "invalid_api_key"}})
        )
      end)

      config = %{api_key: "bad-key", base_url: "http://localhost:#{port}", type: "anthropic"}

      request =
        Adapter.format_request([], [], %{
          model: "claude-sonnet-4-20250514",
          provider_type: "anthropic"
        })

      assert {:error, reason} = Adapter.complete(request, config)
      assert reason != nil
    end

    test "Google complete sends API key in header not URL", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1beta/models/gemini-2.0-flash:generateContent", fn conn ->
        headers = Map.new(conn.req_headers)
        assert headers["x-goog-api-key"] == "secret-key"
        refute conn.query_string =~ "key="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "candidates" => [
              %{"content" => %{"parts" => [%{"text" => "Gemini response"}]}}
            ]
          })
        )
      end)

      config = %{api_key: "secret-key", base_url: "http://localhost:#{port}", type: "google"}

      request =
        Adapter.format_request([], [], %{model: "gemini-2.0-flash", provider_type: "google"})

      request = Map.put(request, :stream, false)
      assert {:ok, "Gemini response"} = Adapter.complete(request, config)
    end

    test "Anthropic complete returns error for unexpected response format", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"unexpected" => "format"}))
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "anthropic"}

      request =
        Adapter.format_request([], [], %{
          model: "claude-sonnet-4-20250514",
          provider_type: "anthropic"
        })

      assert {:error, reason} = Adapter.complete(request, config)
      assert reason =~ "unexpected response"
    end

    test "OpenAI complete returns error for unexpected response format", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"unexpected" => "format"}))
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "openai"}

      request =
        Adapter.format_request([], [], %{model: "gpt-4o", provider_type: "openai"})

      assert {:error, reason} = Adapter.complete(request, config)
      assert reason =~ "unexpected response"
    end

    test "Google complete returns error for unexpected response format", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1beta/models/gemini-2.0-flash:generateContent", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"unexpected" => "format"}))
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "google"}

      request =
        Adapter.format_request([], [], %{model: "gemini-2.0-flash", provider_type: "google"})

      request = Map.put(request, :stream, false)
      assert {:error, reason} = Adapter.complete(request, config)
      assert reason =~ "unexpected response"
    end

    test "OpenAI complete without api_key omits Authorization header", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        headers = Map.new(conn.req_headers)
        refute Map.has_key?(headers, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi"}}]
          })
        )
      end)

      config = %{base_url: "http://localhost:#{port}", type: "openai"}

      request = Adapter.format_request([], [], %{model: "gpt-4o", provider_type: "openai"})

      assert {:ok, "Hi"} = Adapter.complete(request, config)
    end

    test "OpenAI complete returns error message from error response body", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{"error" => %{"message" => "rate_limit_exceeded"}})
        )
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "openai"}

      request = Adapter.format_request([], [], %{model: "gpt-4o", provider_type: "openai"})

      assert {:error, "rate_limit_exceeded"} = Adapter.complete(request, config)
    end
  end

  # ---------------------------------------------------------------------------
  # format_request/3
  # ---------------------------------------------------------------------------

  describe "format_request/3" do
    test "formats for anthropic" do
      messages = [%{role: :user, parts: [%Synapsis.Part.Text{content: "Hello"}]}]

      request =
        Adapter.format_request(messages, [], %{
          model: "claude-sonnet-4-20250514",
          system_prompt: "You are helpful",
          provider_type: "anthropic"
        })

      assert request.model == "claude-sonnet-4-20250514"
      assert request.system == "You are helpful"
      assert request.stream == true
    end

    test "formats for openai" do
      messages = [%{role: :user, parts: [%Synapsis.Part.Text{content: "Hello"}]}]

      request =
        Adapter.format_request(messages, [], %{
          model: "gpt-4o",
          system_prompt: "You are helpful",
          provider_type: "openai"
        })

      assert request.model == "gpt-4o"
      assert length(request.messages) == 2
      assert hd(request.messages).role == "system"
    end

    test "formats for google" do
      messages = [%{role: :user, parts: [%Synapsis.Part.Text{content: "Hello"}]}]

      request =
        Adapter.format_request(messages, [], %{
          model: "gemini-2.0-flash",
          system_prompt: "You are helpful",
          provider_type: "google"
        })

      assert request.model == "gemini-2.0-flash"
      assert request.systemInstruction == %{parts: [%{text: "You are helpful"}]}
    end
  end

  # ---------------------------------------------------------------------------
  # models/1
  # ---------------------------------------------------------------------------

  describe "models/1" do
    test "returns static anthropic models" do
      {:ok, models} = Adapter.models(%{type: "anthropic"})
      assert length(models) >= 3
      ids = Enum.map(models, & &1.id)
      assert "claude-sonnet-4-20250514" in ids
    end

    test "returns static google models" do
      {:ok, models} = Adapter.models(%{type: "google"})
      assert length(models) >= 3
      ids = Enum.map(models, & &1.id)
      assert "gemini-2.0-flash" in ids
    end

    test "fetches openai models from API", %{bypass: bypass, port: port} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "gpt-4o", "context_length" => 128_000},
              %{"id" => "gpt-4o-mini", "context_length" => 128_000}
            ]
          })
        )
      end)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "openai"}
      {:ok, models} = Adapter.models(config)
      assert length(models) == 2
      ids = Enum.map(models, & &1.id)
      assert "gpt-4o" in ids
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_transport_type/1
  # ---------------------------------------------------------------------------

  describe "resolve_transport_type/1" do
    test "maps string types correctly" do
      assert :anthropic = Adapter.resolve_transport_type("anthropic")
      assert :openai = Adapter.resolve_transport_type("openai")
      assert :openai = Adapter.resolve_transport_type("openai_compat")
      assert :openai = Adapter.resolve_transport_type("local")
      assert :openai = Adapter.resolve_transport_type("openrouter")
      assert :openai = Adapter.resolve_transport_type("groq")
      assert :openai = Adapter.resolve_transport_type("deepseek")
      assert :google = Adapter.resolve_transport_type("google")
    end

    test "passes through atoms" do
      assert :anthropic = Adapter.resolve_transport_type(:anthropic)
      assert :openai = Adapter.resolve_transport_type(:openai)
      assert :google = Adapter.resolve_transport_type(:google)
    end

    test "defaults to openai for unknown" do
      assert :openai = Adapter.resolve_transport_type("unknown")
      assert :openai = Adapter.resolve_transport_type(nil)
    end

    test "defaults to openai for unknown atom" do
      assert :openai = Adapter.resolve_transport_type(:unknown_custom)
      assert :openai = Adapter.resolve_transport_type(:foo)
    end

  end

  # ---------------------------------------------------------------------------
  # cancel/1
  # ---------------------------------------------------------------------------

  describe "cancel/1" do
    test "cancel returns :ok" do
      # Start a long-running task under the provider TaskSupervisor so we have a real PID
      task =
        Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
          Process.sleep(:infinity)
        end)

      assert :ok = Adapter.cancel(task.pid)
    end
  end

  # ---------------------------------------------------------------------------
  # stream/2 error handling
  # ---------------------------------------------------------------------------

  describe "stream/2 error handling" do
    test "sends provider_error when connection refused", %{bypass: bypass, port: port} do
      Bypass.down(bypass)

      config = %{api_key: "test-key", base_url: "http://localhost:#{port}", type: "anthropic"}

      request =
        Adapter.format_request([], [], %{
          model: "claude-sonnet-4-20250514",
          system_prompt: "test",
          provider_type: "anthropic"
        })

      assert {:ok, _ref} = Adapter.stream(request, config)

      assert_receive({:provider_error, _reason}, 5000)
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_transport_type/1 — additional edge cases
  # ---------------------------------------------------------------------------

  describe "resolve_transport_type/1 edge cases" do
    test "groq maps to :openai" do
      assert :openai = Adapter.resolve_transport_type("groq")
    end

    test "deepseek maps to :openai" do
      assert :openai = Adapter.resolve_transport_type("deepseek")
    end

    test "integer input defaults to :openai" do
      assert :openai = Adapter.resolve_transport_type(42)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp collect_chunks(ref) do
    collect_chunks(ref, [])
  end

  defp collect_chunks(ref, acc) do
    receive do
      {:provider_chunk, chunk} ->
        collect_chunks(ref, [chunk | acc])

      :provider_done ->
        Enum.reverse(acc)

      {:provider_error, _reason} ->
        Enum.reverse(acc)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Enum.reverse(acc)
    after
      5000 ->
        Enum.reverse(acc)
    end
  end
end
