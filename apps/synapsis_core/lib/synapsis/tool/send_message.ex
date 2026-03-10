defmodule Synapsis.Tool.SendMessage do
  @moduledoc "Send a message to a teammate agent in the swarm."
  use Synapsis.Tool

  @impl true
  def name, do: "send_message"

  @impl true
  def description, do: "Send a message to a teammate agent."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "to" => %{"type" => "string", "description" => "Teammate ID to send to"},
        "content" => %{"type" => "string", "description" => "Message content"},
        "type" => %{
          "type" => "string",
          "enum" => ["request", "response", "notify"],
          "description" => "Message type (default: notify)"
        },
        "in_reply_to" => %{"type" => "string", "description" => "ID of message being replied to"}
      },
      "required" => ["to", "content"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :swarm

  @impl true
  def execute(input, context) do
    session_id = context[:session_id]
    to = input["to"]
    content = input["content"]
    msg_type = input["type"] || "notify"
    in_reply_to = input["in_reply_to"]
    msg_id = Ecto.UUID.generate()

    if is_nil(session_id) do
      {:error, "No session context for swarm messaging"}
    else
      message = %{
        id: msg_id,
        from: context[:agent_id] || "primary",
        to: to,
        content: content,
        type: msg_type,
        in_reply_to: in_reply_to
      }

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "swarm:#{session_id}:#{to}",
        {:swarm_message, message}
      )

      {:ok, Jason.encode!(%{"message_id" => msg_id, "status" => "sent", "to" => to})}
    end
  end
end
