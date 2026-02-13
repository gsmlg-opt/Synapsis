defmodule Synapsis.Provider.EventMapper do
  @moduledoc """
  Pure functions mapping raw decoded JSON from any provider into the canonical
  Anthropic-shaped event tuples consumed by `Session.Worker`.

  The event protocol is:
    :text_start
    {:text_delta, text}
    {:tool_use_start, tool_name, tool_use_id}
    {:tool_input_delta, partial_json}
    {:tool_use_complete, name, args}
    :reasoning_start
    {:reasoning_delta, text}
    :content_block_stop
    :message_start
    {:message_delta, delta_map}
    :done
    {:error, error_map}
    :ignore
  """

  # ---------------------------------------------------------------------------
  # Anthropic — mostly passthrough, already canonical
  # ---------------------------------------------------------------------------

  def map_event(:anthropic, %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use"} = block}) do
    {:tool_use_start, block["name"], block["id"]}
  end

  def map_event(:anthropic, %{"type" => "content_block_start", "content_block" => %{"type" => "text"}}) do
    :text_start
  end

  def map_event(:anthropic, %{"type" => "content_block_start", "content_block" => %{"type" => "thinking"}}) do
    :reasoning_start
  end

  def map_event(:anthropic, %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}) do
    {:text_delta, text}
  end

  def map_event(:anthropic, %{"type" => "content_block_delta", "delta" => %{"type" => "input_json_delta", "partial_json" => json}}) do
    {:tool_input_delta, json}
  end

  def map_event(:anthropic, %{"type" => "content_block_delta", "delta" => %{"type" => "thinking_delta", "thinking" => text}}) do
    {:reasoning_delta, text}
  end

  def map_event(:anthropic, %{"type" => "content_block_stop"}) do
    :content_block_stop
  end

  def map_event(:anthropic, %{"type" => "message_start"}) do
    :message_start
  end

  def map_event(:anthropic, %{"type" => "message_delta"} = data) do
    {:message_delta, data["delta"]}
  end

  def map_event(:anthropic, %{"type" => "message_stop"}) do
    :done
  end

  def map_event(:anthropic, %{"type" => "ping"}) do
    :ignore
  end

  def map_event(:anthropic, %{"type" => "error", "error" => error}) do
    {:error, error}
  end

  def map_event(:anthropic, _), do: :ignore

  # ---------------------------------------------------------------------------
  # OpenAI — translate choices/delta → content_block events
  # ---------------------------------------------------------------------------

  def map_event(:openai, "[DONE]"), do: :done

  def map_event(:openai, %{"choices" => [%{"delta" => %{"content" => content}} | _]})
      when is_binary(content) do
    {:text_delta, content}
  end

  def map_event(:openai, %{"choices" => [%{"delta" => %{"tool_calls" => [call | _]}} | _]}) do
    parse_openai_tool_call(call)
  end

  def map_event(:openai, %{"choices" => [%{"delta" => %{"reasoning_content" => content}} | _]})
      when is_binary(content) do
    {:reasoning_delta, content}
  end

  def map_event(:openai, %{"choices" => [%{"finish_reason" => reason} | _]})
      when reason in ["stop", "end_turn", "tool_calls"] do
    :done
  end

  def map_event(:openai, _), do: :ignore

  # ---------------------------------------------------------------------------
  # Google — translate candidates/parts → content_block events
  # ---------------------------------------------------------------------------

  def map_event(:google, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parse_google_parts(parts)
  end

  def map_event(:google, %{"candidates" => [%{"finishReason" => "STOP"} | _]}) do
    :done
  end

  def map_event(:google, _), do: :ignore

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
end
