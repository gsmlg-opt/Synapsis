defmodule Synapsis.Agent.WorkItem do
  @moduledoc """
  Dispatched work unit from the global assistant to a project assistant.
  """

  @enforce_keys [:work_id, :project_id, :task_type, :payload]
  defstruct [
    :work_id,
    :project_id,
    :task_type,
    :payload,
    :priority,
    :constraints,
    :origin,
    :inserted_at
  ]

  @type t :: %__MODULE__{
          work_id: String.t(),
          project_id: String.t(),
          task_type: atom(),
          payload: map(),
          priority: atom(),
          constraints: map(),
          origin: atom(),
          inserted_at: DateTime.t()
        }

  @valid_priorities [:low, :normal, :high, :critical]

  @spec new(map() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = work_item), do: {:ok, work_item}

  def new(attrs) when is_map(attrs) do
    with {:ok, work_id} <- fetch_binary(attrs, :work_id),
         {:ok, project_id} <- fetch_binary(attrs, :project_id),
         {:ok, task_type} <- fetch_atom(attrs, :task_type),
         {:ok, payload} <- fetch_map(attrs, :payload) do
      priority = normalize_priority(Map.get(attrs, :priority, :normal))

      {:ok,
       %__MODULE__{
         work_id: work_id,
         project_id: project_id,
         task_type: task_type,
         payload: payload,
         priority: priority,
         constraints: Map.get(attrs, :constraints, %{}),
         origin: normalize_origin(Map.get(attrs, :origin, :user)),
         inserted_at: Map.get(attrs, :inserted_at, DateTime.utc_now())
       }}
    end
  end

  def new(_), do: {:error, :invalid_work_item}

  defp fetch_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_atom(attrs, key) do
    case Map.get(attrs, key) do
      value when is_atom(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_map(attrs, key) do
    case Map.get(attrs, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp normalize_priority(value) when value in @valid_priorities, do: value
  defp normalize_priority(_), do: :normal

  defp normalize_origin(value) when is_atom(value), do: value
  defp normalize_origin(_), do: :user
end
