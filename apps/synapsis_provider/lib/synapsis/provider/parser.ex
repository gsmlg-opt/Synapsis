defmodule Synapsis.Provider.Parser do
  @moduledoc """
  Pure functions for parsing provider SSE chunks into domain events.
  No side effects.
  """

  def parse_chunk(data, :anthropic) do
    case data do
      %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use"} = block} ->
        {:tool_use_start, block["name"], block["id"]}

      %{"type" => "content_block_start", "content_block" => %{"type" => "text"}} ->
        :text_start

      %{"type" => "content_block_start", "content_block" => %{"type" => "thinking"}} ->
        :reasoning_start

      %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}} ->
        {:text_delta, text}

      %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "input_json_delta", "partial_json" => json}
      } ->
        {:tool_input_delta, json}

      %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "thinking_delta", "thinking" => text}
      } ->
        {:reasoning_delta, text}

      %{"type" => "content_block_stop"} ->
        :content_block_stop

      %{"type" => "message_start"} ->
        :message_start

      %{"type" => "message_delta"} ->
        {:message_delta, data["delta"]}

      %{"type" => "message_stop"} ->
        :done

      %{"type" => "ping"} ->
        :ignore

      %{"type" => "error", "error" => error} ->
        {:error, error}

      _ ->
        :ignore
    end
  end

  def parse_chunk(data, :openai) do
    case data do
      %{"choices" => [%{"delta" => %{"content" => content}} | _]} when is_binary(content) ->
        {:text_delta, content}

      %{"choices" => [%{"delta" => %{"tool_calls" => [call | _]}} | _]} ->
        parse_openai_tool_call(call)

      %{"choices" => [%{"delta" => %{"reasoning_content" => content}} | _]}
      when is_binary(content) ->
        {:reasoning_delta, content}

      %{"choices" => [%{"finish_reason" => reason} | _]} when reason in ["stop", "end_turn"] ->
        :done

      %{"choices" => [%{"finish_reason" => "tool_calls"} | _]} ->
        :done

      "[DONE]" ->
        :done

      _ ->
        :ignore
    end
  end

  def parse_chunk(data, :google) do
    case data do
      %{"candidates" => [%{"content" => %{"parts" => parts}} | _]} ->
        parse_google_parts(parts)

      %{"candidates" => [%{"finishReason" => "STOP"} | _]} ->
        :done

      _ ->
        :ignore
    end
  end

  defp parse_openai_tool_call(%{"index" => _, "id" => id, "function" => %{"name" => name}}) do
    {:tool_use_start, name, id}
  end

  defp parse_openai_tool_call(%{"function" => %{"arguments" => args}}) when is_binary(args) do
    {:tool_input_delta, args}
  end

  defp parse_openai_tool_call(_), do: :ignore

  defp parse_google_parts([%{"text" => text} | _]) when is_binary(text) do
    {:text_delta, text}
  end

  defp parse_google_parts([%{"functionCall" => %{"name" => name, "args" => args}} | _]) do
    {:tool_use_complete, name, args}
  end

  defp parse_google_parts(_), do: :ignore

  @doc "Parse SSE text lines into decoded JSON events."
  def parse_sse_lines(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, "data: [DONE]") ->
          ["[DONE]"]

        String.starts_with?(line, "data: ") ->
          json_str = String.trim_leading(line, "data: ")

          case Jason.decode(json_str) do
            {:ok, parsed} -> [parsed]
            _ -> []
          end

        true ->
          []
      end
    end)
  end
end
