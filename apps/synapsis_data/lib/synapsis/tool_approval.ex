defmodule Synapsis.ToolApproval do
  @moduledoc """
  Schema for persistent tool approvals (AI-7).

  Tool approvals persist across sessions. Pattern matching supports glob syntax
  for flexible tool and argument matching.

  ## Pattern Syntax

      tool_name                    → exact tool match, any input
      tool_name:arg_pattern        → tool match with argument glob
      shell_exec:git *             → any git command
      file_write:/agents/*/src/** → file writes under any agent workspace src/
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
    field(:scope, Ecto.Enum, values: [:global, :agent])
    field(:agent_name, :string)
    field(:policy, Ecto.Enum, values: [:ask, :record, :allow, :deny])
    field(:created_by, Ecto.Enum, values: [:user, :system])

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:pattern, :scope, :agent_name, :policy, :created_by])
    |> validate_required([:pattern, :scope, :policy, :created_by])
    |> validate_pattern(:pattern)
    |> unique_constraint([:scope, :agent_name, :pattern],
      name: :tool_approvals_scope_agent_pattern_index
    )
    |> unique_constraint([:scope, :pattern], name: :tool_approvals_scope_pattern_global_index)
  end

  # -- Context API --

  @doc "Get a single approval by ID."
  @spec get(String.t()) :: t() | nil
  def get(id), do: Synapsis.Repo.get(__MODULE__, id)

  @doc "List approvals by scope and optional agent."
  @spec list_by_scope(atom() | nil, String.t() | nil) :: [t()]
  def list_by_scope(scope \\ nil, agent_name \\ nil) do
    __MODULE__
    |> maybe_filter(:scope, scope)
    |> maybe_filter(:agent_name, agent_name)
    |> order_by([a], asc: a.pattern)
    |> Synapsis.Repo.all()
  end

  @doc "Load approvals for approval checking: agent-scoped + global."
  @spec load_for_check(String.t() | nil) :: [t()]
  def load_for_check(nil) do
    __MODULE__
    |> where([a], a.scope == :global)
    |> Synapsis.Repo.all()
  end

  def load_for_check(agent_name) do
    __MODULE__
    |> where(
      [a],
      (a.scope == :agent and a.agent_name == ^agent_name) or a.scope == :global
    )
    |> order_by([a], asc: a.scope)
    |> Synapsis.Repo.all()
  end

  @doc "Find existing approval by scope, pattern, and optional agent."
  @spec find_by_pattern(atom(), String.t(), String.t() | nil) :: t() | nil
  def find_by_pattern(scope, pattern, agent_name \\ nil) do
    __MODULE__
    |> where([a], a.scope == ^scope and a.pattern == ^pattern)
    |> maybe_filter(:agent_name, agent_name)
    |> Synapsis.Repo.one()
  end

  @doc "Insert a new approval."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Synapsis.Repo.insert()
  end

  @doc "Insert or update an approval (upsert on scope+agent+pattern)."
  @spec upsert(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    agent_name = attrs[:agent_name] || attrs["agent_name"]

    conflict_opts =
      if agent_name do
        [
          on_conflict: {:replace, [:policy, :updated_at]},
          conflict_target: {:unsafe_fragment, ~s|("scope", "agent_name", "pattern") WHERE agent_name IS NOT NULL|}
        ]
      else
        [
          on_conflict: {:replace, [:policy, :updated_at]},
          conflict_target: {:unsafe_fragment, ~s|("scope", "pattern") WHERE agent_name IS NULL|}
        ]
      end

    %__MODULE__{}
    |> changeset(attrs)
    |> Synapsis.Repo.insert(conflict_opts)
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

  defp maybe_filter(query, :agent_name, agent_name),
    do: where(query, [a], a.agent_name == ^agent_name)

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
