defmodule Synapsis.Workflow.Schema do
  @moduledoc """
  Trusted consumption of one pure Machine schema request.

  The caller explicitly owns and retains a schema/template compute PortSession
  across drives and resumes, then closes it separately. This module consumes
  schema requests only; it does not consume template values or install a native
  tool, workflow executor, persistence or default service. Only a completed
  synchronous compile/validation receipt may acknowledge the exact pending
  request. Unsupported asynchronous policy leaves the pending state unchanged.
  """

  alias Synapsis.Workflow.Machine
  alias Synapsis.Workflow.Schema.PortSession

  @doc "Fulfills the frozen pending request, preserving state on every failure."
  def advance_pending(session, state, timeout_ms) do
    case ack_pending(session, state, timeout_ms) do
      {:ok, %{ack: ack}} -> Machine.advance(state, ack)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Fulfills the already pending request without advancing Machine."
  def ack_pending(
        session,
        %{
          "phase" => "request",
          "heap" => heap,
          "pending_request" => %{"id" => id, "kind" => kind} = request
        },
        timeout_ms
      )
      when kind in ["compile_schema", "validate_response"] do
    outcome = if kind == "compile_schema", do: "compiled", else: "valid"

    case PortSession.fulfill(session, request, heap, timeout_ms) do
      {:ok, %{"id" => ^id, "result" => "ok", "outcome" => ^outcome} = receipt} ->
        {:ok, %{ack: %{"id" => id, "result" => "ok"}, receipt: receipt}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_schema_receipt}
    end
  end

  def ack_pending(_session, %{"phase" => "request", "heap" => _}, _timeout_ms),
    do: {:error, :invalid_schema_request}

  def ack_pending(_session, _state, _timeout_ms), do: {:error, :no_pending_schema_request}
end
