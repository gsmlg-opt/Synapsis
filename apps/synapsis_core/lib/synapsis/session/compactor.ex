defmodule Synapsis.Session.Compactor do
  @moduledoc "Compacts old messages when approaching context window limit."

  alias Synapsis.{Repo, Message, ContextWindow}
  import Ecto.Query

  @model_limits %{
    "claude-sonnet-4-20250514" => 200_000,
    "claude-opus-4-20250514" => 200_000,
    "claude-3-5-sonnet-20241022" => 200_000,
    "gpt-4o" => 128_000,
    "gpt-4o-mini" => 128_000,
    "gpt-4-turbo" => 128_000,
    "gemini-2.0-flash" => 1_048_576,
    "gemini-2.0-pro" => 1_048_576
  }

  @default_limit 128_000

  def maybe_compact(session_id, model) do
    messages = load_messages(session_id)
    limit = model_limit(model)

    if ContextWindow.needs_compaction?(messages, limit) do
      compact(session_id, messages)
    else
      :ok
    end
  end

  def compact(session_id, messages) do
    {to_compact, _to_keep} = ContextWindow.partition_for_compaction(messages, keep_recent: 10)

    if to_compact == [] do
      :ok
    else
      summary = summarize_messages(to_compact)

      Repo.transaction(fn ->
        # Delete old messages
        ids = Enum.map(to_compact, & &1.id)

        from(m in Message, where: m.id in ^ids)
        |> Repo.delete_all()

        # Insert summary message
        {:ok, _msg} =
          %Message{}
          |> Message.changeset(%{
            session_id: session_id,
            role: "system",
            parts: [%Synapsis.Part.Text{content: summary}],
            token_count: ContextWindow.estimate_tokens(summary)
          })
          |> Repo.insert()
      end)

      :compacted
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
    #{String.slice(parts, 0, 4000)}
    [End Summary]
    """
  end

  defp extract_text(parts) do
    parts
    |> Enum.map(fn
      %Synapsis.Part.Text{content: c} -> c
      %Synapsis.Part.ToolUse{tool: t, input: i} -> "[tool_use: #{t}(#{inspect(i)})]"
      %Synapsis.Part.ToolResult{content: c} -> "[tool_result: #{String.slice(c, 0, 200)}]"
      %Synapsis.Part.Reasoning{content: c} -> "[reasoning: #{String.slice(c, 0, 200)}]"
      _ -> ""
    end)
    |> Enum.join(" ")
    |> String.slice(0, 500)
  end

  defp load_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  defp model_limit(model) do
    Map.get(@model_limits, model, @default_limit)
  end
end
