defmodule Synapsis.Tool.AgentSend do
  @moduledoc "Fire-and-forget message to another agent."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_send"

  @impl true
  def description,
    do:
      "Send a fire-and-forget message to another agent. The message is persisted and delivered via PubSub."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "to" => %{
          "type" => "string",
          "description" =>
            "Target agent ID (e.g. \"global\", \"project:{id}\", \"session:{id}\", UUID)"
        },
        "content" => %{"type" => "string", "description" => "Message content"},
        "type" => %{
          "type" => "string",
          "enum" => ["notification", "info", "warning"],
          "description" => "Message type (default: notification)"
        },
        "metadata" => %{"type" => "object", "description" => "Optional metadata map"}
      },
      "required" => ["to", "content"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :communication

  @impl true
  def execute(input, context) do
    to = input["to"]
    content = input["content"]
    msg_type = input["type"] || "notification"
    metadata = input["metadata"] || %{}
    from = resolve_agent_id(context)
    ref = Ecto.UUID.generate()

    attrs = %{
      ref: ref,
      from_agent_id: from,
      to_agent_id: to,
      type: msg_type,
      payload: %{"content" => content, "metadata" => metadata},
      project_id: context[:project_id],
      session_id: context[:session_id]
    }

    case Synapsis.AgentMessages.create(attrs) do
      {:ok, message} ->
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "agent:#{to}",
          {:agent_envelope,
           %{
             from: from,
             to: to,
             ref: ref,
             type: String.to_atom(msg_type),
             payload: message.payload,
             timestamp: message.inserted_at
           }}
        )

        {:ok, Jason.encode!(%{message_id: message.id, ref: ref, status: "sent", to: to})}

      {:error, changeset} ->
        {:error, "Failed to send message: #{inspect(changeset.errors)}"}
    end
  end

  defp resolve_agent_id(context) do
    context[:agent_id] || context[:session_id] || "unknown"
  end
end
