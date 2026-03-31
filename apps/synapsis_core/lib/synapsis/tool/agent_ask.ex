defmodule Synapsis.Tool.AgentAsk do
  @moduledoc "Request/response message to another agent with blocking wait."
  use Synapsis.Tool

  @impl true
  def name, do: "agent_ask"

  @impl true
  def description,
    do:
      "Send a request to another agent and block until a response is received. Sub-agents cannot use this (deadlock prevention)."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "to" => %{"type" => "string", "description" => "Target agent ID"},
        "question" => %{"type" => "string", "description" => "Question or request content"},
        "context" => %{"type" => "object", "description" => "Optional context map"},
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Timeout in ms (default 120000, max 300000)"
        }
      },
      "required" => ["to", "question"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :communication

  @impl true
  def execute(input, context) do
    if context[:parent_agent] do
      {:error, "Sub-agents cannot use agent_ask (deadlock prevention). Use agent_send instead."}
    else
      do_ask(input, context)
    end
  end

  defp do_ask(input, context) do
    to = input["to"]
    question = input["question"]
    ctx = input["context"] || %{}
    timeout = min(input["timeout_ms"] || 120_000, 300_000)
    from = context[:agent_id] || context[:session_id] || "unknown"
    ref = Ecto.UUID.generate()

    attrs = %{
      ref: ref,
      from_agent_id: from,
      to_agent_id: to,
      type: "request",
      payload: %{"question" => question, "context" => ctx},
      project_id: context[:project_id],
      session_id: context[:session_id],
      expires_at: DateTime.add(DateTime.utc_now(), timeout, :millisecond)
    }

    # Subscribe to response topic before persisting
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent_reply:#{ref}")

    case Synapsis.AgentMessages.create(attrs) do
      {:ok, message} ->
        # Broadcast request to target agent
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "agent:#{to}",
          {:agent_envelope,
           %{
             from: from,
             to: to,
             ref: ref,
             type: :request,
             payload: message.payload,
             timestamp: message.inserted_at
           }}
        )

        # Block waiting for response
        receive do
          {:agent_reply, ^ref, response} ->
            Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "agent_reply:#{ref}")
            {:ok, Jason.encode!(%{ref: ref, response: response, status: "received"})}
        after
          timeout ->
            Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "agent_reply:#{ref}")
            Synapsis.AgentMessages.update_status(message, "expired")
            {:error, "Request timed out after #{timeout}ms"}
        end

      {:error, _changeset} ->
        Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "agent_reply:#{ref}")
        {:error, "Failed to send request"}
    end
  end
end
