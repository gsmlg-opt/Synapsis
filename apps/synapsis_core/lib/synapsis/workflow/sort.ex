defmodule Synapsis.Workflow.Sort do
  @moduledoc """
  Trusted consumption of Machine sort requests through the existing compute owner.

  The caller retains and closes the PortSession. Only the completed, correlated
  occurrence permutation is forwarded; Machine retains the original item roots.
  """

  alias Synapsis.Workflow.Machine
  alias Synapsis.Workflow.Schema.PortSession

  @doc "Fulfills the pending sort request, preserving state on every failure."
  def advance_pending(session, state, timeout_ms) do
    case ack_pending(session, state, timeout_ms) do
      {:ok, %{ack: ack}} -> Machine.advance(state, ack)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Returns the correlated sort ACK and receipt without advancing Machine."
  def ack_pending(
        session,
        %{
          "phase" => "request",
          "heap" => heap,
          "pending_request" => %{"id" => id, "kind" => "sort_items"} = request
        },
        timeout_ms
      ) do
    case PortSession.fulfill(session, request, heap, timeout_ms) do
      {:ok,
       %{"id" => ^id, "result" => "ok", "outcome" => "sorted", "indices" => indices} = receipt} ->
        {:ok,
         %{
           ack: %{
             "id" => id,
             "kind" => "sort_items",
             "result" => "ok",
             "indices" => indices
           },
           receipt: receipt
         }}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_sort_receipt}
    end
  end

  def ack_pending(_session, %{"phase" => "request", "heap" => _}, _timeout_ms),
    do: {:error, :invalid_sort_request}

  def ack_pending(_session, _state, _timeout_ms), do: {:error, :no_pending_sort_request}
end
