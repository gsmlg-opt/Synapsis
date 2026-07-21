defmodule Synapsis.ToolApproval do
  @moduledoc """
  Persisted tool-approval rules (pattern → policy), global or per-agent.

  ADR-006 C4: an `embedded_schema` (no DB table) with a Concord-backed context.
  Rules are node-local coordination data under `coord/tool_approvals/`.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Concord.Turso, as: KV

  @type t :: %__MODULE__{}
  @prefix "coord/tool_approvals/"

  @primary_key {:id, :binary_id, autogenerate: false}
  embedded_schema do
    field(:pattern, :string)
    field(:scope, Ecto.Enum, values: [:global, :agent])
    field(:agent_name, :string)
    field(:policy, Ecto.Enum, values: [:ask, :record, :allow, :deny])
    field(:created_by, Ecto.Enum, values: [:user, :system])

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:id, :pattern, :scope, :agent_name, :policy, :created_by])
    |> validate_required([:pattern, :scope, :policy])
    |> validate_pattern(:pattern)
  end

  # ── context (Concord-backed Turso) ──────────────────────────────────────────

  @spec get(String.t()) :: t() | nil
  def get(id) do
    case KV.get(@prefix <> id) do
      {:ok, map} -> struct(__MODULE__, map)
      _ -> nil
    end
  end

  @spec list_by_scope(atom() | nil, String.t() | nil) :: [t()]
  def list_by_scope(scope \\ nil, agent_name \\ nil) do
    scan()
    |> filter_scope(scope)
    |> filter_agent(agent_name)
    |> Enum.sort_by(& &1.pattern)
  end

  @spec load_for_check(String.t() | nil) :: [t()]
  def load_for_check(nil), do: Enum.filter(scan(), &(&1.scope == :global))

  def load_for_check(agent_name) do
    scan()
    |> Enum.filter(fn a ->
      a.scope == :global or (a.scope == :agent and a.agent_name == agent_name)
    end)
    |> Enum.sort_by(& &1.scope)
  end

  @spec find_by_pattern(atom(), String.t(), String.t() | nil) :: t() | nil
  def find_by_pattern(scope, pattern, agent_name \\ nil) do
    Enum.find(scan(), fn a ->
      a.scope == scope and a.pattern == pattern and
        (is_nil(agent_name) or a.agent_name == agent_name)
    end)
  end

  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: persist(changeset(%__MODULE__{}, attrs))

  @spec upsert(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    scope = attrs[:scope] || attrs["scope"]
    pattern = attrs[:pattern] || attrs["pattern"]
    agent_name = attrs[:agent_name] || attrs["agent_name"]

    case find_by_pattern(scope, pattern, agent_name) do
      nil -> create(attrs)
      existing -> update(existing, attrs)
    end
  end

  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = approval, attrs), do: persist(changeset(approval, attrs))

  @spec delete(t()) :: {:ok, t()}
  def delete(%__MODULE__{id: id} = approval) do
    KV.delete(@prefix <> id)
    {:ok, approval}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp persist(%Ecto.Changeset{valid?: true} = changeset) do
    now = DateTime.utc_now()

    record =
      changeset
      |> apply_changes()
      |> then(&%{&1 | id: &1.id || Ecto.UUID.generate(), updated_at: now})
      |> then(&%{&1 | inserted_at: &1.inserted_at || now})

    case KV.put(@prefix <> record.id, Map.from_struct(record)) do
      :ok -> {:ok, record}
      {:ok, _} -> {:ok, record}
      other -> {:error, other}
    end
  end

  defp persist(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp scan do
    case KV.prefix_scan(@prefix) do
      # WORKAROUND(upstream): gsmlg-dev/concord#23 — prefix_scan skips decompression.
      {:ok, pairs} ->
        Enum.map(pairs, fn {_k, v} -> struct(__MODULE__, Concord.Compression.decompress(v)) end)

      _ ->
        []
    end
  end

  defp filter_scope(list, nil), do: list
  defp filter_scope(list, scope), do: Enum.filter(list, &(&1.scope == scope))
  defp filter_agent(list, nil), do: list
  defp filter_agent(list, agent), do: Enum.filter(list, &(&1.agent_name == agent))

  defp validate_pattern(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      if is_binary(value) and value != "", do: [], else: [{field, "must be a non-empty string"}]
    end)
  end
end
