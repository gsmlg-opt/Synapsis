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
  import Ecto.Query

  @type t :: %__MODULE__{}

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

  # -- Context API --

  @doc "Get a single approval by ID."
  @spec get(String.t()) :: t() | nil
  def get(id), do: Synapsis.Repo.get(__MODULE__, id)

  @doc "List approvals by scope and optional project."
  @spec list_by_scope(atom() | nil, String.t() | nil) :: [t()]
  def list_by_scope(scope \\ nil, project_id \\ nil) do
    __MODULE__
    |> maybe_filter(:scope, scope)
    |> maybe_filter(:project_id, project_id)
    |> order_by([a], asc: a.pattern)
    |> Synapsis.Repo.all()
  end

  @doc "Load approvals for approval checking: project-scoped + global."
  @spec load_for_check(String.t() | nil) :: [t()]
  def load_for_check(nil) do
    __MODULE__
    |> where([a], a.scope == :global)
    |> Synapsis.Repo.all()
  end

  def load_for_check(project_id) do
    __MODULE__
    |> where(
      [a],
      (a.scope == :project and a.project_id == ^project_id) or a.scope == :global
    )
    |> order_by([a], asc: a.scope)
    |> Synapsis.Repo.all()
  end

  @doc "Find existing approval by scope, pattern, and optional project."
  @spec find_by_pattern(atom(), String.t(), String.t() | nil) :: t() | nil
  def find_by_pattern(scope, pattern, project_id \\ nil) do
    __MODULE__
    |> where([a], a.scope == ^scope and a.pattern == ^pattern)
    |> maybe_filter(:project_id, project_id)
    |> Synapsis.Repo.one()
  end

  @doc "Insert a new approval."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Synapsis.Repo.insert()
  end

  @doc "Insert or update an approval (upsert on scope+project+pattern)."
  @spec upsert(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Synapsis.Repo.insert(
      on_conflict: {:replace, [:policy, :updated_at]},
      conflict_target: [:scope, :project_id, :pattern]
    )
  end

  @doc "Update an existing approval."
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = approval, attrs) do
    approval
    |> changeset(attrs)
    |> Synapsis.Repo.update()
  end

  @doc "Delete an approval."
  @spec delete(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def delete(%__MODULE__{} = approval) do
    Synapsis.Repo.delete(approval)
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :scope, scope), do: where(query, [a], a.scope == ^scope)

  defp maybe_filter(query, :project_id, pid),
    do: where(query, [a], a.project_id == ^pid)

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
