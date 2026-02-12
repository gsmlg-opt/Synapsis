defmodule Synapsis.Provider.AnthropicTest do
  use ExUnit.Case

  alias Synapsis.Provider.Anthropic

  setup do
    bypass = Bypass.open()
    config = %{api_key: "test-key", base_url: "http://localhost:#{bypass.port}"}
    %{bypass: bypass, config: config}
  end

  describe "stream/2" do
    test "receives streaming chunks", %{bypass: bypass, config: config} do
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

      request =
        Anthropic.format_request([], [], %{
          model: "claude-sonnet-4-20250514",
          system_prompt: "test"
        })

      assert {:ok, ref} = Anthropic.stream(request, config)

      chunks = collect_chunks(ref)
      text_deltas = for {:text_delta, text} <- chunks, do: text
      assert "Hello" in text_deltas
      assert " world" in text_deltas
      assert :done in chunks
    end

    test "handles error response", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{"error" => %{"type" => "authentication_error"}})
        )
      end)

      request = Anthropic.format_request([], [], %{model: "claude-sonnet-4-20250514"})
      assert {:ok, ref} = Anthropic.stream(request, config)

      # Should receive done or error eventually
      assert_receive(:provider_done, 5000)
    end
  end

  describe "format_request/3" do
    test "formats basic request" do
      messages = [
        %{role: :user, parts: [%Synapsis.Part.Text{content: "Hello"}]}
      ]

      request =
        Anthropic.format_request(messages, [], %{
          model: "claude-sonnet-4-20250514",
          system_prompt: "You are helpful"
        })

      assert request.model == "claude-sonnet-4-20250514"
      assert request.system == "You are helpful"
      assert request.stream == true
      assert length(request.messages) == 1
    end

    test "includes tools when provided" do
      tools = [
        %{name: "file_read", description: "Read a file", parameters: %{type: "object"}}
      ]

      request = Anthropic.format_request([], tools, %{model: "claude-sonnet-4-20250514"})
      assert length(request.tools) == 1
    end
  end

  describe "models/1" do
    test "returns static model list" do
      {:ok, models} = Anthropic.models(%{})
      assert length(models) >= 3
      ids = Enum.map(models, & &1.id)
      assert "claude-sonnet-4-20250514" in ids
    end
  end

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
