defmodule Synapsis.Tool.AgentHandoff do
  @moduledoc "Delegate work to another agent with workspace artifacts."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_handoff"

  @impl true
  def description,
    do:
      "Delegate work to another agent with a summary, instructions, and optional workspace artifacts."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "to" => %{"type" => "string", "description" => "Target agent ID"},
        "summary" => %{"type" => "string", "description" => "Summary of work to delegate"},
        "instructions" => %{
          "type" => "string",
          "description" => "Detailed instructions for the agent"
        },
        "artifacts" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Array of @synapsis/ paths to workspace artifacts"
        },
        "priority" => %{
          "type" => "string",
          "enum" => ["low", "normal", "high", "critical"],
          "description" => "Priority level (default: normal)"
        },
        "constraints" => %{"type" => "object", "description" => "Optional constraints map"}
      },
      "required" => ["to", "summary", "instructions"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :communication

  @impl true
  def side_effects, do: [:workspace_changed]

  @impl true
  def execute(input, context) do
    to = input["to"]
    summary = input["summary"]
    instructions = input["instructions"]
    artifacts = input["artifacts"] || []
    priority = input["priority"] || "normal"
    constraints = input["constraints"] || %{}
    from = context[:agent_id] || context[:session_id] || "unknown"
    ref = Ecto.UUID.generate()

    handoff_payload = %{
      "summary" => summary,
      "instructions" => instructions,
      "artifacts" => artifacts,
      "priority" => priority,
      "constraints" => constraints
    }

    attrs = %{
      ref: ref,
      from_agent_id: from,
      to_agent_id: to,
      type: "handoff",
      payload: handoff_payload,
      project_id: context[:project_id],
      session_id: context[:session_id]
    }

    case Synapsis.AgentMessages.create(attrs) do
      {:ok, message} ->
        # Write handoff record to workspace if project_id is available
        maybe_write_workspace_handoff(context[:project_id], ref, handoff_payload, from, to)

        # Broadcast delegation to target agent
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "agent:#{to}",
          {:agent_envelope,
           %{
             from: from,
             to: to,
             ref: ref,
             type: :handoff,
             payload: message.payload,
             timestamp: message.inserted_at
           }}
        )

        # Broadcast side effect
        if context[:session_id] do
          payload = {:tool_effect, :workspace_changed, %{ref: ref, type: "handoff"}}

          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "tool_effects:#{context[:session_id]}",
            payload
          )

          Phoenix.PubSub.broadcast(Synapsis.PubSub, "tool_effects:global", payload)
        end

        {:ok, Jason.encode!(%{message_id: message.id, ref: ref, status: "delegated", to: to})}

      {:error, _changeset} ->
        {:error, "Failed to create handoff"}
    end
  end

  defp maybe_write_workspace_handoff(nil, _ref, _payload, _from, _to), do: :ok

  defp maybe_write_workspace_handoff(project_id, ref, payload, from, to) do
    path = "/projects/#{project_id}/handoffs/#{ref}.json"

    handoff_doc =
      Jason.encode!(%{
        ref: ref,
        from: from,
        to: to,
        payload: payload,
        created_at: DateTime.utc_now()
      })

    if Code.ensure_loaded?(Synapsis.Workspace) and
         function_exported?(Synapsis.Workspace, :write, 3) do
      apply(Synapsis.Workspace, :write, [
        path,
        handoff_doc,
        %{kind: "handoff", content_format: "json", created_by: from}
      ])
    end

    :ok
  end
end
