defmodule Synapsis.Provider.RequestHistory do
  @moduledoc "Target-specific request history for explicit session model changes."

  alias Backplane.AiProtocol.Error

  @affinity_keys [
    :profile,
    :endpoint,
    :account,
    :workspace,
    :model,
    :credential_scope,
    :credential_version
  ]

  def project(messages, protocol, opts) do
    messages = Enum.flat_map(messages, &project_message(&1, Atom.to_string(protocol), opts))

    case validate_tool_pairs(messages) do
      :ok -> {:ok, messages}
      {:error, _} = error -> error
    end
  end

  defp project_message(message, protocol, opts) do
    incompatible? = fn
      %{type: :provider_state, state: state} -> incompatible_origin?(state, protocol, opts)
      _block -> false
    end

    changed_origin? = Enum.any?(message.content, incompatible?)

    content =
      Enum.reject(message.content, fn block ->
        incompatible?.(block) or (changed_origin? and block.type == :reasoning)
      end)

    if content == [], do: [], else: [%{message | content: content}]
  end

  defp incompatible_origin?(state, protocol, opts) do
    affinity = state.affinity

    # Missing or inconsistent origins remain in the request so the strict codec
    # rejects them. Only a valid, explicitly different origin is projected out.
    complete? =
      Enum.all?([affinity.profile, affinity.endpoint, affinity.model], fn value ->
        is_binary(value) and value != ""
      end)

    consistent? =
      state.source_profile == affinity.profile and
        (is_nil(affinity.protocol) or state.source_protocol == affinity.protocol)

    complete? and consistent? and
      (state.source_protocol != protocol or
         Enum.any?(@affinity_keys, fn key ->
           expected = Map.get(affinity, key)
           not is_nil(expected) and expected != Keyword.get(opts, key)
         end))
  end

  defp validate_tool_pairs(messages) do
    Enum.reduce_while(messages, {:ok, MapSet.new(), MapSet.new()}, fn message, acc ->
      case validate_message(message, acc) do
        {:ok, _seen, _pending} = next -> {:cont, next}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen, pending} ->
        if MapSet.size(pending) == 0,
          do: :ok,
          else: Error.invalid("Model-switch history has a tool call without its result")

      {:error, _} = error ->
        error
    end
  end

  defp validate_message(%{role: :tool, tool_call_id: id}, {:ok, seen, pending}) do
    if MapSet.member?(pending, id),
      do: {:ok, seen, MapSet.delete(pending, id)},
      else: Error.invalid("Model-switch history has an orphan tool result")
  end

  defp validate_message(%{content: content}, acc) do
    Enum.reduce_while(content, acc, fn
      %{type: :tool_call, tool_call: %{id: id}}, {:ok, seen, pending} ->
        if MapSet.member?(seen, id),
          do: {:halt, Error.invalid("Model-switch history has a duplicate tool call ID")},
          else: {:cont, {:ok, MapSet.put(seen, id), MapSet.put(pending, id)}}

      _block, state ->
        {:cont, state}
    end)
  end
end
