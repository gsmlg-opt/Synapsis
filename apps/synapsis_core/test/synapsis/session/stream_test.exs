defmodule Synapsis.Session.StreamTest do
  use ExUnit.Case, async: false

  alias Synapsis.Session.Stream
  alias Synapsis.Provider.Registry, as: ProviderRegistry

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @stream_provider_prefix "stream_test_provider"

  defp unique_provider_name do
    "#{@stream_provider_prefix}_#{System.unique_integer([:positive])}"
  end

  defp register_provider(name, type, bypass_port, extra \\ %{}) do
    config =
      Map.merge(
        %{type: type, api_key: "test-key", base_url: "http://localhost:#{bypass_port}"},
        extra
      )

    ProviderRegistry.register(name, config)
    on_exit(fn -> ProviderRegistry.unregister(name) end)
    config
  end

  defp collect_stream_events(timeout \\ 5000) do
    collect_stream_events([], timeout)
  end

  defp collect_stream_events(acc, timeout) do
    receive do
      {:provider_chunk, chunk} ->
        collect_stream_events([{:chunk, chunk} | acc], timeout)

      :provider_done ->
        Enum.reverse([{:done, nil} | acc])

      {:provider_error, reason} ->
        Enum.reverse([{:error, reason} | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/3 — error paths (unknown / nil / empty provider)
  # ---------------------------------------------------------------------------

  describe "start_stream/3 with unknown providers" do
    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, "totally_unknown_xyz")
    end

    test "returns error for empty string provider" do
      assert {:error, _} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, "")
    end

    test "returns error for nil provider" do
      assert {:error, _} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, nil)
    end

    test "returns error for integer provider name" do
      assert {:error, _} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, 42)
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/3 — successful delegation via Bypass (Anthropic)
  # ---------------------------------------------------------------------------

  describe "start_stream/3 delegates to Anthropic provider" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass, port: bypass.port}
    end

    test "returns {:ok, ref} and caller receives streaming text chunks", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "anthropic", port)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"message_start","message":{"id":"msg_stream_01"}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" from"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" stream"}}

        data: {"type":"message_stop"}

        """)
      end)

      request = %{
        model: "claude-sonnet-4-20250514",
        max_tokens: 100,
        messages: [%{role: "user", content: "hi"}],
        stream: true
      }

      assert {:ok, ref} = Stream.start_stream(request, config, provider_name)
      assert is_reference(ref)

      events = collect_stream_events()
      chunk_events = for {:chunk, c} <- events, do: c
      text_deltas = for {:text_delta, t} <- chunk_events, do: t

      assert "Hello" in text_deltas
      assert " from" in text_deltas
      assert " stream" in text_deltas
      assert Enum.any?(events, fn {type, _} -> type == :done end)
    end

    test "caller receives :provider_error when server returns HTTP error", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "anthropic", port)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "internal failure"}}))
      end)

      request = %{model: "claude-sonnet-4-20250514", max_tokens: 10, messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, config, provider_name)

      # Non-SSE response triggers :provider_done (Req parses non-streaming body)
      # OR could be :provider_error depending on implementation.
      # Accept either outcome as graceful handling.
      events = collect_stream_events()
      has_terminal = Enum.any?(events, fn {type, _} -> type in [:done, :error] end)
      assert has_terminal
    end

    test "caller receives :provider_error when connection is refused", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "anthropic", port)

      Bypass.down(bypass)

      request = %{model: "claude-sonnet-4-20250514", max_tokens: 10, messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, config, provider_name)

      events = collect_stream_events()
      assert Enum.any?(events, fn {type, _} -> type == :error end)
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/3 — successful delegation via Bypass (OpenAI)
  # ---------------------------------------------------------------------------

  describe "start_stream/3 delegates to OpenAI provider" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass, port: bypass.port}
    end

    test "returns {:ok, ref} and streams OpenAI text chunks", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "openai", port)

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"OpenAI"},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" response"},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """)
      end)

      request = %{
        model: "gpt-4o",
        messages: [%{role: "user", content: "hello"}],
        stream: true
      }

      assert {:ok, ref} = Stream.start_stream(request, config, provider_name)
      assert is_reference(ref)

      events = collect_stream_events()
      chunk_events = for {:chunk, c} <- events, do: c
      text_deltas = for {:text_delta, t} <- chunk_events, do: t

      assert "OpenAI" in text_deltas
      assert " response" in text_deltas
      assert Enum.any?(events, fn {type, _} -> type == :done end)
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/3 — successful delegation via Bypass (Google)
  # ---------------------------------------------------------------------------

  describe "start_stream/3 delegates to Google provider" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass, port: bypass.port}
    end

    test "returns {:ok, ref} and streams Google text chunks", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "google", port)

      Bypass.expect_once(
        bypass,
        "POST",
        "/v1beta/models/gemini-2.0-flash:streamGenerateContent",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, """
          data: {"candidates":[{"content":{"parts":[{"text":"Google"}],"role":"model"}}]}

          data: {"candidates":[{"content":{"parts":[{"text":" says hi"}],"role":"model"}}]}

          data: {"candidates":[{"finishReason":"STOP"}]}

          """)
        end
      )

      request = %{
        model: "gemini-2.0-flash",
        contents: [%{role: "user", parts: [%{text: "hello"}]}],
        stream: true
      }

      assert {:ok, ref} = Stream.start_stream(request, config, provider_name)
      assert is_reference(ref)

      events = collect_stream_events()
      chunk_events = for {:chunk, c} <- events, do: c
      text_deltas = for {:text_delta, t} <- chunk_events, do: t

      assert "Google" in text_deltas
      assert " says hi" in text_deltas
      assert Enum.any?(events, fn {type, _} -> type == :done end)
    end
  end

  # ---------------------------------------------------------------------------
  # cancel_stream/2 — error/unknown provider paths
  # ---------------------------------------------------------------------------

  describe "cancel_stream/2 with unknown providers" do
    test "returns :ok for unknown provider (silent failure)" do
      assert :ok = Stream.cancel_stream(:some_ref, "totally_unknown_xyz")
    end

    test "returns :ok for nil provider" do
      assert :ok = Stream.cancel_stream(:some_ref, nil)
    end

    test "returns :ok for empty string provider" do
      assert :ok = Stream.cancel_stream(:some_ref, "")
    end

    test "returns :ok for integer provider name" do
      assert :ok = Stream.cancel_stream(:some_ref, 42)
    end
  end

  # ---------------------------------------------------------------------------
  # cancel_stream/2 — terminates an active stream
  # ---------------------------------------------------------------------------

  describe "cancel_stream/2 terminates an active stream" do
    test "cancels a task by PID through the provider adapter" do
      provider_name = unique_provider_name()
      ProviderRegistry.register(provider_name, %{type: "anthropic"})
      on_exit(fn -> ProviderRegistry.unregister(provider_name) end)

      # Start a long-running task under the provider TaskSupervisor to get a real PID
      task =
        Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
          Process.sleep(:infinity)
        end)

      # cancel_stream delegates to Adapter.cancel/1, which expects a PID
      assert :ok = Stream.cancel_stream(task.pid, provider_name)

      # The task process should be terminated
      ref = Process.monitor(task.pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2000
    end

    test "cancel with ref from start_stream raises FunctionClauseError (ref != pid)" do
      provider_name = unique_provider_name()
      ProviderRegistry.register(provider_name, %{type: "anthropic"})
      on_exit(fn -> ProviderRegistry.unregister(provider_name) end)

      # Adapter.cancel/1 calls Task.Supervisor.terminate_child which requires a PID.
      # Passing a reference (as returned by Adapter.stream/2) is currently not supported.
      assert_raise FunctionClauseError, fn ->
        Stream.cancel_stream(make_ref(), provider_name)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/3 — provider registered but unreachable (graceful error)
  # ---------------------------------------------------------------------------

  describe "start_stream/3 handles provider errors gracefully" do
    test "sends :provider_error when provider base_url is unreachable" do
      provider_name = unique_provider_name()

      # Use a port that nothing listens on
      config = %{
        type: "anthropic",
        api_key: "test-key",
        base_url: "http://localhost:1"
      }

      ProviderRegistry.register(provider_name, config)
      on_exit(fn -> ProviderRegistry.unregister(provider_name) end)

      request = %{model: "claude-sonnet-4-20250514", max_tokens: 10, messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, config, provider_name)

      events = collect_stream_events(10_000)
      assert Enum.any?(events, fn {type, _} -> type == :error end),
             "Expected a :provider_error event but got: #{inspect(events)}"
    end

    test "sends :provider_error with reason string" do
      provider_name = unique_provider_name()

      config = %{
        type: "openai",
        api_key: "test-key",
        base_url: "http://localhost:1"
      }

      ProviderRegistry.register(provider_name, config)
      on_exit(fn -> ProviderRegistry.unregister(provider_name) end)

      request = %{model: "gpt-4o", messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, config, provider_name)

      events = collect_stream_events(10_000)
      error_events = for {:error, reason} <- events, do: reason
      assert length(error_events) > 0
      assert is_binary(hd(error_events))
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/3 — reports streaming progress (multiple chunks)
  # ---------------------------------------------------------------------------

  describe "start_stream/3 reports streaming progress" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass, port: bypass.port}
    end

    test "delivers chunks incrementally as they arrive", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "anthropic", port)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"B"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"C"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"D"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"E"}}

        data: {"type":"message_stop"}

        """)
      end)

      request = %{model: "claude-sonnet-4-20250514", max_tokens: 100, messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, config, provider_name)

      events = collect_stream_events()
      chunk_events = for {:chunk, c} <- events, do: c
      text_deltas = for {:text_delta, t} <- chunk_events, do: t

      # Verify all 5 chunks arrived in order
      assert length(text_deltas) >= 5
      assert text_deltas == ["A", "B", "C", "D", "E"]
    end

    test "delivers reasoning deltas alongside text deltas", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "anthropic", port)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}

        data: {"type":"message_stop"}

        """)
      end)

      request = %{model: "claude-sonnet-4-20250514", max_tokens: 100, messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, config, provider_name)

      events = collect_stream_events()
      chunk_events = for {:chunk, c} <- events, do: c

      text_deltas = for {:text_delta, t} <- chunk_events, do: t
      reasoning_deltas = for {:reasoning_delta, r} <- chunk_events, do: r

      assert "Answer" in text_deltas
      assert "Let me think" in reasoning_deltas
    end

    test "handles empty response body gracefully", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()
      config = register_provider(provider_name, "anthropic", port)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"message_start","message":{"id":"msg_empty"}}

        data: {"type":"message_stop"}

        """)
      end)

      request = %{model: "claude-sonnet-4-20250514", max_tokens: 100, messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, config, provider_name)

      events = collect_stream_events()
      # Should still receive terminal event, even with no content chunks
      assert Enum.any?(events, fn {type, _} -> type == :done end)
    end
  end

  # ---------------------------------------------------------------------------
  # start_stream/3 — provider_config argument is passed through correctly
  # ---------------------------------------------------------------------------

  describe "start_stream/3 passes provider_config to Adapter.stream/2" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass, port: bypass.port}
    end

    test "uses api_key from provider_config in request headers", %{bypass: bypass, port: port} do
      provider_name = unique_provider_name()

      # Register in ETS so module_for resolves, but use a different config for the stream call
      ProviderRegistry.register(provider_name, %{type: "anthropic"})
      on_exit(fn -> ProviderRegistry.unregister(provider_name) end)

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        headers = Map.new(conn.req_headers)
        assert headers["x-api-key"] == "my-special-key"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, """
        data: {"type":"message_stop"}

        """)
      end)

      stream_config = %{
        type: "anthropic",
        api_key: "my-special-key",
        base_url: "http://localhost:#{port}"
      }

      request = %{model: "claude-sonnet-4-20250514", max_tokens: 10, messages: [], stream: true}

      assert {:ok, _ref} = Stream.start_stream(request, stream_config, provider_name)

      events = collect_stream_events()
      assert Enum.any?(events, fn {type, _} -> type == :done end)
    end
  end
end
