defmodule Synapsis.ToolApproval do
  @moduledoc """
  Schema for persistent tool approvals (AI-7).

  Tool approvals persist across sessions. Pattern matching supports glob syntax
  for flexible tool and argument matching.

  ## Pattern Syntax

      tool_name                    → exact tool match, any input
      tool_name:arg_pattern        → tool match with argument glob
      shell_exec:git *             → any git command
      file_write:/projects/*/src/** → file writes under any project src/
      file_read:*                  → all file reads (blanket allow)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tool_approvals" do
    field(:pattern, :string)
    field(:scope, Ecto.Enum, values: [:global, :project])
    field(:policy, Ecto.Enum, values: [:ask, :record, :allow, :deny])
    field(:created_by, Ecto.Enum, values: [:user, :system])

    belongs_to(:project, Synapsis.Project)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:pattern, :scope, :project_id, :policy, :created_by])
    |> validate_required([:pattern, :scope, :policy, :created_by])
    |> validate_pattern(:pattern)
    |> unique_constraint([:scope, :project_id, :pattern])
  end

  @doc """
  Check if a tool invocation matches this approval pattern.

  Returns `true` if the tool name and arguments match the pattern.
  """
  @spec matches?(%__MODULE__{}, String.t(), map()) :: boolean()
  def matches?(%__MODULE__{pattern: pattern}, tool_name, input) do
    case String.split(pattern, ":", parts: 2) do
      [name_pattern] ->
        glob_match?(name_pattern, tool_name)

      [name_pattern, arg_pattern] ->
        glob_match?(name_pattern, tool_name) and
          arg_matches?(arg_pattern, input)
    end
  end

  defp glob_match?("*", _value), do: true
  defp glob_match?(pattern, value), do: pattern == value

  defp arg_matches?("*", _input), do: true

  defp arg_matches?(pattern, input) when is_map(input) do
    input_str =
      input
      |> Map.values()
      |> Enum.map(&to_string/1)
      |> Enum.join(" ")

    simple_glob_match?(pattern, input_str)
  end

  defp arg_matches?(pattern, input) when is_binary(input) do
    simple_glob_match?(pattern, input)
  end

  defp arg_matches?(_pattern, _input), do: false

  defp simple_glob_match?(pattern, value) do
    regex_str =
      pattern
      |> String.replace("**", "<<<DOUBLESTAR>>>")
      |> String.replace("*", "[^/]*")
      |> String.replace("<<<DOUBLESTAR>>>", ".*")
      |> then(&("^" <> &1 <> "$"))

    case Regex.compile(regex_str) do
      {:ok, regex} -> Regex.match?(regex, value)
      _ -> false
    end
  end

  defp validate_pattern(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      if is_binary(value) and byte_size(value) > 0 do
        []
      else
        [{field, "must be a non-empty string"}]
      end
    end)
  end
end
