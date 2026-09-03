defmodule Synapsis.Agent.TestSupport.DeterministicProvider do
  @moduledoc """
  Bypass-backed OpenAI-compatible provider double for lifecycle tests.

  Supported scenarios:

  - `:success` — single text completion
  - `:streamed_success` — multiple text deltas then finish
  - `:provider_failure` — HTTP 500
  - `:timeout` — HTTP 408 (wall-clock hang avoided in CI)
  - `:malformed_tool_request` — tool call with invalid JSON arguments
  - `:multi_turn_tool_result` — first turn tool call, second turn text

  Does not contact real model providers or the public network.
  """

  @chat_path "/v1/chat/completions"

  @type scenario ::
          :success
          | :streamed_success
          | :provider_failure
          | :timeout
          | :malformed_tool_request
          | :multi_turn_tool_result

  @type harness :: %{
          bypass: map(),
          name: String.t(),
          base_url: String.t(),
          scenario: scenario(),
          tool_name: String.t() | nil,
          tool_call_id: String.t() | nil,
          counter: pid() | nil
        }

  @doc """
  Start a Bypass server, install the scenario handler, and register a provider.

  Options:

  - `:scenario` (default `:success`)
  - `:name` — provider registry name (default unique)
  - `:text` — completion text for success scenarios
  - `:stream_chunks` — list of text strings for `:streamed_success`
  - `:tool_name`, `:tool_call_id`, `:tool_args` — for tool scenarios
  - `:counter` — optional Agent pid; each request appends the decoded body
  """
  @spec start!(keyword()) :: harness()
  def start!(opts \\ []) do
    scenario = Keyword.get(opts, :scenario, :success)
    suffix = System.unique_integer([:positive, :monotonic])
    name = Keyword.get(opts, :name, "deterministic_provider_#{suffix}")
    tool_name = Keyword.get(opts, :tool_name)
    tool_call_id = Keyword.get(opts, :tool_call_id, "det-call-#{suffix}")
    tool_args = Keyword.get(opts, :tool_args, %{"value" => "verified"})
    text = Keyword.get(opts, :text, "deterministic success")
    stream_chunks = Keyword.get(opts, :stream_chunks, ["deterministic ", "streamed ", "success"])
    counter = Keyword.get(opts, :counter)

    bypass = Bypass.open()

    install!(bypass, scenario, %{
      text: text,
      stream_chunks: stream_chunks,
      tool_name: tool_name,
      tool_call_id: tool_call_id,
      tool_args: tool_args,
      counter: counter
    })

    base_url = "http://localhost:#{bypass.port}"

    :ok =
      Synapsis.Provider.Registry.register(name, %{
        type: "openai",
        api_key: "test-key",
        base_url: base_url
      })

    %{
      bypass: bypass,
      name: name,
      base_url: base_url,
      scenario: scenario,
      tool_name: tool_name,
      tool_call_id: tool_call_id,
      counter: counter
    }
  end

  @doc "Unregister the provider. Bypass closes with the test process."
  @spec stop(harness()) :: :ok
  def stop(%{name: name}) do
    Synapsis.Provider.Registry.unregister(name)
    :ok
  end

  @doc "Install a scenario handler on an existing Bypass."
  @spec install!(map(), scenario(), map()) :: :ok
  def install!(bypass, scenario, ctx \\ %{}) do
    Bypass.expect(bypass, "POST", @chat_path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      maybe_record(ctx[:counter], request)
      handle_request(conn, scenario, request, ctx)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # SSE builders (shared with characterization / release-readiness tests)
  # ---------------------------------------------------------------------------

  def text_chunk(text, id \\ "det-response") do
    %{
      "id" => id,
      "choices" => [
        %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}
      ]
    }
  end

  def tool_call_chunk(tool_name, tool_call_id, args, id \\ "det-response-tool") do
    arguments =
      case args do
        bin when is_binary(bin) -> bin
        map when is_map(map) -> Jason.encode!(map)
      end

    %{
      "id" => id,
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => tool_call_id,
                "type" => "function",
                "function" => %{
                  "name" => tool_name,
                  "arguments" => arguments
                }
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }
  end

  def finish_chunk(reason) do
    %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]}
  end

  def send_sse(conn, chunks) do
    body =
      Enum.map_join(chunks, "\n\n", fn chunk -> "data: #{Jason.encode!(chunk)}" end) <>
        "\n\ndata: [DONE]\n\n"

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end

  # ---------------------------------------------------------------------------
  # Scenario handlers
  # ---------------------------------------------------------------------------

  defp handle_request(conn, :success, _request, ctx) do
    send_sse(conn, [text_chunk(ctx.text), finish_chunk("stop")])
  end

  defp handle_request(conn, :streamed_success, _request, ctx) do
    chunks =
      Enum.map(ctx.stream_chunks, &text_chunk/1) ++ [finish_chunk("stop")]

    send_sse(conn, chunks)
  end

  defp handle_request(conn, :provider_failure, _request, _ctx) do
    Plug.Conn.send_resp(conn, 500, "deterministic provider failure")
  end

  defp handle_request(conn, :timeout, _request, _ctx) do
    # Surface a timeout-class failure without sleeping past Req receive_timeout.
    Plug.Conn.send_resp(conn, 408, "Request Timeout")
  end

  defp handle_request(conn, :malformed_tool_request, _request, ctx) do
    tool_name = ctx.tool_name || raise(":malformed_tool_request requires :tool_name")
    tool_call_id = ctx.tool_call_id

    send_sse(conn, [
      tool_call_chunk(tool_name, tool_call_id, "{not-json", "det-malformed"),
      finish_chunk("tool_calls")
    ])
  end

  defp handle_request(conn, :multi_turn_tool_result, request, ctx) do
    tool_name = ctx.tool_name || raise(":multi_turn_tool_result requires :tool_name")
    tool_call_id = ctx.tool_call_id
    turn = request_turn(request)

    case turn do
      1 ->
        send_sse(conn, [
          tool_call_chunk(tool_name, tool_call_id, ctx.tool_args),
          finish_chunk("tool_calls")
        ])

      _ ->
        send_sse(conn, [text_chunk(ctx.text || "tool path complete"), finish_chunk("stop")])
    end
  end

  defp request_turn(request) when is_map(request) do
    messages = request["messages"] || []

    has_tool_result? =
      Enum.any?(messages, fn
        %{"role" => "tool"} ->
          true

        %{"role" => "user", "content" => content} when is_list(content) ->
          Enum.any?(content, fn
            %{"type" => "tool_result"} -> true
            _ -> false
          end)

        _ ->
          false
      end)

    if has_tool_result?, do: 2, else: 1
  end

  defp maybe_record(nil, _request), do: :ok

  defp maybe_record(counter, request) when is_pid(counter) do
    Agent.update(counter, fn state ->
      requests = Map.get(state, :provider_requests, [])
      Map.put(state, :provider_requests, requests ++ [request])
    end)
  end
end
