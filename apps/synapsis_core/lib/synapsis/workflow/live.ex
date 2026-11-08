defmodule Synapsis.Workflow.Live do
  @moduledoc """
  Finite host adapter publishing pure Machine transitions to private provenance.

  The caller retains the volatile binding outside Machine and durable snapshots.
  State paths are captured trusted source context, not selected or admitted here.
  The admitted Agent driver can publish a precomputed transition, including a
  state read's parse and carry while Local still holds the file lock.
  """

  alias Synapsis.Workflow.{Machine, Value}
  alias Synapsis.Workflow.Provenance.Owner

  def open(server, machine, timeout_ms),
    do: Owner.open(server, self(), machine["heap"], timeout_ms)

  def advance(binding, machine, event, source_context, timeout_ms) do
    publish_observed(
      binding,
      machine,
      Machine.advance_observed(machine, event),
      source_context,
      timeout_ms
    )
  end

  def publish_observed(
        binding,
        _machine,
        {{:error, _} = result, _observations},
        _source_context,
        _timeout_ms
      ),
      do: {:ok, result, binding}

  def publish_observed(binding, machine, {transition, observations}, source_context, timeout_ms) do
    with {:ok, actions} <- actions(observations, machine["pending_request"], source_context),
         next = elem(transition, tuple_size(transition) - 1),
         {:ok, binding} <-
           Owner.publish(
             binding,
             Value.heap_delta(machine["heap"], next["heap"]),
             actions,
             timeout_ms
           ) do
      {:ok, transition, binding}
    end
  end

  def resume(binding, machine, response, timeout_ms) do
    publish_observed(
      binding,
      machine,
      Machine.resume_observed(machine, response),
      nil,
      timeout_ms
    )
  end

  def release(binding, timeout_ms), do: Owner.release(binding, timeout_ms)
  def retire(binding, timeout_ms), do: Owner.retire(binding, timeout_ms)

  defp actions(observations, pending, context) do
    Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, actions} ->
      case action(observation, pending, context) do
        {:ok, nil} -> {:cont, {:ok, actions}}
        {:ok, action} -> {:cont, {:ok, actions ++ [action]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp action({:copy_mark, _source, _target} = action, _pending, _context), do: {:ok, action}

  defp action(
         {:state_written, id, root, text},
         %{"id" => id, "kind" => "state_set", "value" => root, "text" => text},
         %{request_id: id, lexical_path: path}
       )
       when is_binary(path) and is_binary(text),
       do: {:ok, {:remember, path, text, root}}

  defp action(
         {:state_read, id, root, text},
         %{"id" => id, "kind" => "state_get"},
         %{request_id: id, lexical_path: path}
       )
       when is_binary(path) and is_binary(text),
       do: {:ok, {:carry_remembered, path, text, root}}

  # Missing-file null preserves the existing semantic ACK without inventing
  # captured text or a remembered provenance match.
  defp action(
         {:state_read, id, _root, nil},
         %{"id" => id, "kind" => "state_get"},
         %{request_id: id, lexical_path: path}
       )
       when is_binary(path),
       do: {:ok, nil}

  defp action(_observation, _pending, _context), do: {:error, :invalid_source_context}
end
