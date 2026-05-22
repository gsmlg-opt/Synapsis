defmodule Synapsis.Harness.Context do
  @moduledoc "Pure fold state for a harness session aggregate."

  alias Synapsis.Harness.Event

  defstruct [
    :session_id,
    :agent_id,
    :parent_id,
    status: :new,
    metadata: %{},
    messages: [],
    current_step: nil,
    pending_tools: %{},
    pending_permission: nil,
    accumulating_parts: %{},
    permissions: %{},
    assistant_message_id: nil,
    provider_request: %{},
    available_tools: %{},
    budgets: %{}
  ]

  def new(attrs \\ []) do
    struct!(__MODULE__, attrs)
  end

  def apply_event(event, %__MODULE__{} = context), do: apply_event(context, event)

  def apply_event(%__MODULE__{} = context, %Event.SessionCreated{} = event) do
    %{
      context
      | session_id: event.aggregate_id,
        agent_id: event.agent_id,
        parent_id: event.parent_id,
        metadata: event.metadata,
        status: :idle
    }
  end

  def apply_event(%__MODULE__{} = context, %Event.MessageAppended{message: message}) do
    context = %{context | messages: context.messages ++ [Map.put_new(message, :parts, [])]}

    case Map.get(message, :role, Map.get(message, "role")) do
      :user -> %{context | status: :generating}
      _role -> context
    end
  end

  def apply_event(%__MODULE__{} = context, %Event.PartAppended{
        message_id: message_id,
        part: part
      }) do
    update_message(context, message_id, fn message ->
      Map.update(message, :parts, [part], &(&1 ++ [part]))
    end)
  end

  def apply_event(%__MODULE__{} = context, %Event.PartUpdated{
        message_id: message_id,
        part_id: part_id,
        patch: patch
      }) do
    context =
      update_message(context, message_id, fn message ->
        parts =
          Enum.map(message.parts || [], fn
            %{id: ^part_id} = part -> deep_merge(part, patch)
            part -> part
          end)

        %{message | parts: parts}
      end)

    if committed_part_update?(patch) do
      delete_accumulating_part(context, part_id)
    else
      context
    end
  end

  def apply_event(%__MODULE__{} = context, %Event.StepStarted{} = event) do
    %{
      context
      | status: :generating,
        current_step: %{
          step_id: event.step_id,
          model_id: event.model_id,
          message_id: event.message_id
        },
        assistant_message_id: event.message_id
    }
  end

  def apply_event(%__MODULE__{} = context, %Event.StepFinished{} = event) do
    status =
      cond do
        event.stop_reason == :end_turn ->
          :idle

        context.pending_permission ->
          :awaiting_permission

        map_size(context.pending_tools) > 0 ->
          :executing_tools

        event.stop_reason == :tool_use ->
          :await_step_decision

        true ->
          context.status
      end

    %{
      context
      | current_step: nil,
        status: status,
        budgets: apply_usage(context.budgets, event.usage),
        assistant_message_id: maybe_clear_assistant_message(context.assistant_message_id, status)
    }
  end

  def apply_event(%__MODULE__{} = context, %Event.ToolInvoked{} = event) do
    pending_tool = %{
      message_id: event.message_id,
      part_id: event.part_id,
      tool_name: event.tool_name,
      args: event.args
    }

    %{context | pending_tools: Map.put(context.pending_tools, event.part_id, pending_tool)}
  end

  def apply_event(%__MODULE__{} = context, %Event.ToolReturned{part_id: part_id}) do
    pending_tools = Map.delete(context.pending_tools, part_id)
    status = if map_size(pending_tools) == 0, do: :generating, else: context.status

    %{context | pending_tools: pending_tools, status: status}
  end

  def apply_event(%__MODULE__{} = context, %Event.PermissionRequested{} = event) do
    %{
      context
      | status: :awaiting_permission,
        pending_permission: %{
          request_id: event.request_id,
          part_id: event.part_id,
          effect_class: event.effect_class,
          tool_call: event.tool_call
        }
    }
  end

  def apply_event(%__MODULE__{} = context, %Event.PermissionGranted{request_id: request_id}) do
    %{
      context
      | pending_permission: nil,
        permissions: Map.put(context.permissions, request_id, :granted)
    }
  end

  def apply_event(%__MODULE__{} = context, %Event.PermissionDenied{request_id: request_id}) do
    %{
      context
      | pending_permission: nil,
        permissions: Map.put(context.permissions, request_id, :denied)
    }
  end

  def apply_event(%__MODULE__{} = context, %Event.Aborted{}) do
    %{
      context
      | status: :aborted,
        current_step: nil,
        pending_tools: %{},
        pending_permission: nil,
        accumulating_parts: %{}
    }
  end

  def apply_event(%__MODULE__{} = context, _event), do: context

  def put_accumulating_part(%__MODULE__{} = context, part_id, part) do
    %{context | accumulating_parts: Map.put(context.accumulating_parts, part_id, part)}
  end

  def update_accumulating_part(%__MODULE__{} = context, part_id, fun) do
    %{context | accumulating_parts: Map.update!(context.accumulating_parts, part_id, fun)}
  end

  def delete_accumulating_part(%__MODULE__{} = context, part_id) do
    %{context | accumulating_parts: Map.delete(context.accumulating_parts, part_id)}
  end

  defp update_message(context, message_id, fun) do
    messages =
      Enum.map(context.messages, fn
        %{id: ^message_id} = message -> fun.(message)
        message -> message
      end)

    %{context | messages: messages}
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp apply_usage(budgets, usage) when is_map(usage) do
    input_tokens = Map.get(usage, :input_tokens, Map.get(usage, "input_tokens", 0))
    output_tokens = Map.get(usage, :output_tokens, Map.get(usage, "output_tokens", 0))
    used = Map.get(budgets, :tokens_used, 0) + input_tokens + output_tokens

    Map.put(budgets, :tokens_used, used)
  end

  defp apply_usage(budgets, _usage), do: budgets

  defp maybe_clear_assistant_message(_message_id, :idle), do: nil
  defp maybe_clear_assistant_message(message_id, _status), do: message_id

  defp committed_part_update?(%{data: %{state: state}}) do
    state in [:awaiting_permission, :running, :completed, :failed, :denied]
  end

  defp committed_part_update?(%{"data" => %{"state" => state}}) do
    state in ["awaiting_permission", "running", "completed", "failed", "denied"]
  end

  defp committed_part_update?(_patch), do: false
end
