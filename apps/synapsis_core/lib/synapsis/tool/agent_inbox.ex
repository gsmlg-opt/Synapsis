defmodule Synapsis.Tool.AgentInbox do
  @moduledoc "Read message history, unread messages, or follow a thread."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_inbox"

  @impl true
  def description,
    do:
      "Read agent messages: unread, history, or thread by ref. Marks retrieved unread messages as read."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["unread", "history", "thread"],
          "description" => "Inbox action"
        },
        "ref" => %{"type" => "string", "description" => "Thread ref (for 'thread' action)"},
        "limit" => %{"type" => "integer", "description" => "Max messages to return (default 20)"},
        "since" => %{
          "type" => "string",
          "description" => "ISO datetime for history start (for 'history' action)"
        },
        "type" => %{"type" => "string", "description" => "Filter by message type"}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :communication

  @impl true
  def execute(input, context) do
    agent_id = context[:agent_id] || context[:session_id]

    if is_nil(agent_id) do
      {:error, "No agent context available"}
    else
      case input["action"] do
        "unread" -> get_unread(agent_id, input)
        "history" -> get_history(agent_id, input)
        "thread" -> get_thread(input)
        other -> {:error, "Unknown action: #{other}"}
      end
    end
  end

  defp get_unread(agent_id, input) do
    opts = [
      limit: input["limit"] || 20,
      type: input["type"]
    ]

    messages = Synapsis.AgentMessages.unread(agent_id, opts)

    # Mark as read
    Enum.each(messages, &Synapsis.AgentMessages.mark_read/1)

    {:ok,
     Jason.encode!(%{
       messages: Enum.map(messages, &format_message/1),
       count: length(messages)
     })}
  end

  defp get_history(agent_id, input) do
    opts = [
      limit: input["limit"] || 20,
      since: input["since"],
      type: input["type"]
    ]

    messages = Synapsis.AgentMessages.history(agent_id, opts)

    {:ok,
     Jason.encode!(%{
       messages: Enum.map(messages, &format_message/1),
       count: length(messages)
     })}
  end

  defp get_thread(input) do
    ref = input["ref"]

    if is_nil(ref) do
      {:error, "ref is required for 'thread' action"}
    else
      messages = Synapsis.AgentMessages.thread(ref, limit: input["limit"] || 50)

      {:ok,
       Jason.encode!(%{
         messages: Enum.map(messages, &format_message/1),
         count: length(messages),
         ref: ref
       })}
    end
  end

  defp format_message(msg) do
    %{
      "id" => msg.id,
      "ref" => msg.ref,
      "from" => msg.from_agent_id,
      "to" => msg.to_agent_id,
      "type" => msg.type,
      "status" => msg.status,
      "payload" => msg.payload,
      "in_reply_to" => msg.in_reply_to,
      "created_at" => DateTime.to_iso8601(msg.inserted_at)
    }
  end
end
