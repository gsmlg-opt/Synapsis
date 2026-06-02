defmodule Synapsis.Session.Compactor do
  @moduledoc "Compacts old messages when approaching context window limit."

  alias Synapsis.{Message, ContextWindow}
  alias Synapsis.Provider.ModelRegistry

  @default_limit 128_000
  @summary_char_cap 4_000

  def maybe_compact(session_id, model, opts \\ []) do
    messages = load_messages(session_id)
    limit = model_limit(model)
    extra_tokens = Keyword.get(opts, :extra_tokens, 0)

    if ContextWindow.needs_compaction?(messages, limit, extra_tokens: extra_tokens) do
      compact(session_id, messages)
    else
      {:ok, :no_compaction_needed}
    end
  end

  def compact(session_id, messages) do
    {to_compact, to_keep} = ContextWindow.partition_for_compaction(messages, keep_recent: 10)

    if to_compact == [] do
      {:ok, :no_compaction_needed}
    else
      summary = summarize_messages(to_compact)
      summary_tokens = ContextWindow.estimate_tokens(summary)

      # ADR-006 C4: rewrite the durable turn list as [summary | kept] atomically.
      summary_message = %Message{
        session_id: session_id,
        role: "system",
        parts: [%Synapsis.Part.Text{content: summary}],
        token_count: summary_tokens
      }

      :ok = Message.persist_list(session_id, [summary_message | to_keep])

      {:ok,
       %{
         removed: length(to_compact),
         kept: length(to_keep),
         summary_tokens: summary_tokens
       }}
    end
  end

  defp summarize_messages(messages) do
    parts =
      messages
      |> Enum.map(fn msg ->
        role = msg.role
        text = extract_text(msg.parts)
        "[#{role}] #{text}"
      end)
      |> Enum.join("\n")

    """
    [Context Summary - #{length(messages)} messages compacted]
    #{String.slice(parts, 0, @summary_char_cap)}
    [End Summary]
    """
  end

  defp extract_text(parts) do
    parts
    |> Enum.map(fn
      %Synapsis.Part.Text{content: c} -> c
      %Synapsis.Part.ToolUse{tool: t, input: i} -> "[tool_use: #{t}(#{inspect(i)})]"
      %Synapsis.Part.ToolResult{content: c} -> "[tool_result: #{String.slice(c || "", 0, 200)}]"
      %Synapsis.Part.Reasoning{content: c} -> "[reasoning: #{String.slice(c || "", 0, 200)}]"
      _ -> ""
    end)
    |> Enum.join(" ")
    |> String.slice(0, 500)
  end

  defp load_messages(session_id), do: Message.list_by_session(session_id)

  defp model_limit(model) do
    case ModelRegistry.get(model) do
      {:ok, meta} -> meta.context_window
      {:error, :unknown} -> @default_limit
    end
  end
end
