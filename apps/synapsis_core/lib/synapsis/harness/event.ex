defmodule Synapsis.Harness.Event do
  @moduledoc "Pure event ADTs for the harness session aggregate."

  defmodule SessionCreated do
    @moduledoc "Session aggregate was created."
    defstruct [
      :event_id,
      :aggregate_id,
      :version,
      :inserted_at,
      :agent_id,
      :parent_id,
      metadata: %{}
    ]
  end

  defmodule MessageAppended do
    @moduledoc "A message was appended to the session."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :message]
  end

  defmodule PartAppended do
    @moduledoc "A part was appended to a message."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :message_id, :part]
  end

  defmodule PartUpdated do
    @moduledoc "A part was updated by patch."
    defstruct [
      :event_id,
      :aggregate_id,
      :version,
      :inserted_at,
      :message_id,
      :part_id,
      patch: %{}
    ]
  end

  defmodule StepStarted do
    @moduledoc "A provider generation step started."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :step_id, :model_id, :message_id]
  end

  defmodule StepFinished do
    @moduledoc "A provider generation step finished."
    defstruct [
      :event_id,
      :aggregate_id,
      :version,
      :inserted_at,
      :step_id,
      :stop_reason,
      usage: %{}
    ]
  end

  defmodule ToolInvoked do
    @moduledoc "A tool invocation became durable."
    defstruct [
      :event_id,
      :aggregate_id,
      :version,
      :inserted_at,
      :message_id,
      :part_id,
      :tool_name,
      args: %{}
    ]
  end

  defmodule ToolReturned do
    @moduledoc "A tool invocation returned a result or error."
    defstruct [
      :event_id,
      :aggregate_id,
      :version,
      :inserted_at,
      :message_id,
      :part_id,
      :result,
      :error
    ]
  end

  defmodule PermissionRequested do
    @moduledoc "Tool execution is waiting on a user permission decision."
    defstruct [
      :event_id,
      :aggregate_id,
      :version,
      :inserted_at,
      :request_id,
      :part_id,
      :effect_class,
      :tool_call
    ]
  end

  defmodule PermissionGranted do
    @moduledoc "User granted a permission request."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :request_id]
  end

  defmodule PermissionDenied do
    @moduledoc "User denied a permission request."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :request_id, :reason]
  end

  defmodule Aborted do
    @moduledoc "Session turn was aborted."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :reason]
  end

  defmodule Compacted do
    @moduledoc "Messages were compacted into a summary part."
    defstruct [
      :event_id,
      :aggregate_id,
      :version,
      :inserted_at,
      replaced_message_ids: [],
      summary_part: nil
    ]
  end

  def session_created(session_id, opts) do
    %SessionCreated{
      aggregate_id: session_id,
      agent_id: Keyword.fetch!(opts, :agent_id),
      parent_id: Keyword.get(opts, :parent_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def message_appended(session_id, message) do
    %MessageAppended{aggregate_id: session_id, message: message}
  end

  def part_appended(session_id, message_id, part) do
    %PartAppended{aggregate_id: session_id, message_id: message_id, part: part}
  end

  def part_updated(session_id, message_id, part_id, patch) do
    %PartUpdated{
      aggregate_id: session_id,
      message_id: message_id,
      part_id: part_id,
      patch: patch
    }
  end

  def step_started(session_id, step_id, model_id, message_id) do
    %StepStarted{
      aggregate_id: session_id,
      step_id: step_id,
      model_id: model_id,
      message_id: message_id
    }
  end

  def step_finished(session_id, step_id, stop_reason, usage \\ %{}) do
    %StepFinished{
      aggregate_id: session_id,
      step_id: step_id,
      stop_reason: stop_reason,
      usage: usage || %{}
    }
  end

  def tool_invoked(session_id, message_id, part_id, tool_name, args) do
    %ToolInvoked{
      aggregate_id: session_id,
      message_id: message_id,
      part_id: part_id,
      tool_name: tool_name,
      args: args
    }
  end

  def tool_returned(session_id, message_id, part_id, result_or_error) do
    build_tool_returned(session_id, message_id, part_id, result_or_error)
  end

  def permission_requested(session_id, request_id, part_id, effect_class, tool_call \\ nil) do
    %PermissionRequested{
      aggregate_id: session_id,
      request_id: request_id,
      part_id: part_id,
      effect_class: effect_class,
      tool_call: tool_call
    }
  end

  def permission_granted(session_id, request_id) do
    %PermissionGranted{aggregate_id: session_id, request_id: request_id}
  end

  def permission_denied(session_id, request_id, reason) do
    %PermissionDenied{aggregate_id: session_id, request_id: request_id, reason: reason}
  end

  def aborted(session_id, reason), do: %Aborted{aggregate_id: session_id, reason: reason}

  def compacted(session_id, replaced_message_ids, summary_part) do
    %Compacted{
      aggregate_id: session_id,
      replaced_message_ids: replaced_message_ids,
      summary_part: summary_part
    }
  end

  defp build_tool_returned(session_id, message_id, part_id, {:ok, result}) do
    %ToolReturned{
      aggregate_id: session_id,
      message_id: message_id,
      part_id: part_id,
      result: result
    }
  end

  defp build_tool_returned(session_id, message_id, part_id, {:error, error}) do
    %ToolReturned{
      aggregate_id: session_id,
      message_id: message_id,
      part_id: part_id,
      error: error
    }
  end
end
