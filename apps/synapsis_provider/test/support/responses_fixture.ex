defmodule Synapsis.Provider.TestSupport.ResponsesFixture do
  @moduledoc false

  def text_delta(text), do: %{"type" => "response.output_text.delta", "delta" => text}

  def function_call(name, call_id, arguments) do
    %{
      "type" => "function_call",
      "id" => "item_#{call_id}",
      "call_id" => call_id,
      "name" => name,
      "arguments" => if(is_binary(arguments), do: arguments, else: Jason.encode!(arguments))
    }
  end

  def completed(output \\ [], attrs \\ %{}) do
    %{"type" => "response.completed", "response" => response(output, attrs)}
  end

  def response(output, attrs \\ %{}) do
    Map.merge(%{"status" => "completed", "output" => output}, attrs)
  end

  def message(text) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end

  def tool_events(item, index) do
    [
      %{
        "type" => "response.output_item.added",
        "output_index" => index,
        "item" => %{item | "arguments" => ""}
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => item["id"],
        "delta" => item["arguments"]
      },
      %{"type" => "response.output_item.done", "output_index" => index, "item" => item}
    ]
  end

  def send_sse(conn, events) do
    # Fixtures can declare complete function calls alongside their other events.
    {events, _calls} =
      Enum.flat_map_reduce(events, [], fn
        %{"type" => "function_call"} = call, calls ->
          {tool_events(call, length(calls)), calls ++ [call]}

        %{"type" => "response.completed", "response" => %{"output" => []}} = event, calls ->
          {[put_in(event, ["response", "output"], calls)], calls}

        event, calls ->
          {[event], calls}
      end)

    body = Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))

    if conn.state == :chunked do
      {:ok, conn} = Plug.Conn.chunk(conn, body)
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end
  end
end
