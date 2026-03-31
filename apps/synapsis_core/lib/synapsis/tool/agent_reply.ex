defmodule Synapsis.Tool.AgentReply do
  @moduledoc "Reply to a received request from another agent."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_reply"

  @impl true
  def description,
    do:
      "Reply to a request received from another agent. The ref from the incoming request is required."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "ref" => %{
          "type" => "string",
          "description" => "Correlation ref from the incoming request"
        },
        "content" => %{"type" => "string", "description" => "Reply content"},
        "status" => %{
          "type" => "string",
          "enum" => ["success", "error", "partial", "declined"],
          "description" => "Reply status (default: success)"
        }
      },
      "required" => ["ref", "content"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :communication

  @impl true
  def execute(input, context) do
    ref = input["ref"]
    content = input["content"]
    status = input["status"] || "success"
    from = context[:agent_id] || context[:session_id] || "unknown"

    # Find the original request to determine who to reply to
    case Synapsis.AgentMessages.get_by_ref(ref) do
      nil ->
        {:error, "No request found with ref #{ref}"}

      original ->
        reply_to = original.from_agent_id
        reply_ref = Ecto.UUID.generate()

        attrs = %{
          ref: reply_ref,
          from_agent_id: from,
          to_agent_id: reply_to,
          type: "response",
          in_reply_to: original.id,
          payload: %{"content" => content, "status" => status},
          project_id: context[:project_id],
          session_id: context[:session_id]
        }

        case Synapsis.AgentMessages.create(attrs) do
          {:ok, message} ->
            # Mark original as acknowledged
            Synapsis.AgentMessages.update_status(original, "acknowledged")

            # Wake the blocking agent_ask via the reply topic
            Phoenix.PubSub.broadcast(
              Synapsis.PubSub,
              "agent_reply:#{ref}",
              {:agent_reply, ref, %{"content" => content, "status" => status}}
            )

            # Also deliver to agent's general topic
            Phoenix.PubSub.broadcast(
              Synapsis.PubSub,
              "agent:#{reply_to}",
              {:agent_envelope,
               %{
                 from: from,
                 to: reply_to,
                 ref: reply_ref,
                 type: :response,
                 payload: message.payload,
                 timestamp: message.inserted_at
               }}
            )

            {:ok,
             Jason.encode!(%{
               message_id: message.id,
               ref: reply_ref,
               in_reply_to: ref,
               status: "sent"
             })}

          {:error, _changeset} ->
            {:error, "Failed to send reply"}
        end
    end
  end
end
