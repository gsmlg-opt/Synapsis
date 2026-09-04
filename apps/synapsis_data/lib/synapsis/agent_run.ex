defmodule Synapsis.AgentRun do
  @moduledoc """
  Daemon run record for manual, heartbeat, dream, and scheduled work.

  ADR-006 C4: an `embedded_schema` (no DB table). Run records are node-local
  coordination data; this struct is the in-memory shape and changeset surface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @kinds ~w(manual heartbeat dream schedule)
  @statuses ~w(
    queued starting running waiting_approval sleeping
    completed failed cancelled timed_out unknown_outcome
  )
  @sources ~w(web system oban scheduler)
  @tool_profiles ~w(read_only reflect heartbeat coding maintenance dangerous)
  @terminal_statuses ~w(completed failed cancelled timed_out unknown_outcome)

  @cast_fields [
    :id,
    :kind,
    :status,
    :source,
    :assistant_name,
    :project_ref,
    :workspace_ref,
    :session_id,
    :heartbeat_id,
    :routine_id,
    :parent_run_id,
    :attempt,
    :idempotency_key,
    :scheduled_for,
    :deadline_at,
    :prompt,
    :tool_profile,
    :policy_snapshot,
    :capability_snapshot,
    :model,
    :provider,
    :summary,
    :error,
    :failure_class,
    :recovery_state,
    :started_at,
    :finished_at,
    :last_event_sequence,
    :revision,
    :metadata
  ]

  embedded_schema do
    field(:kind, :string)
    field(:status, :string, default: "queued")
    field(:source, :string, default: "system")
    field(:assistant_name, :string)
    field(:project_ref, :string)
    field(:workspace_ref, :string)
    field(:session_id, :binary_id)
    field(:heartbeat_id, :binary_id)
    field(:routine_id, :binary_id)
    field(:parent_run_id, :binary_id)
    field(:attempt, :integer, default: 1)
    field(:idempotency_key, :string)
    field(:scheduled_for, :utc_datetime_usec)
    field(:deadline_at, :utc_datetime_usec)
    field(:prompt, :string)
    field(:tool_profile, :string, default: "read_only")
    field(:policy_snapshot, :map, default: %{})
    field(:capability_snapshot, :map, default: %{})
    field(:model, :string)
    field(:provider, :string)
    field(:summary, :string)
    field(:error, :string)
    field(:failure_class, :string)
    field(:recovery_state, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:last_event_sequence, :integer, default: 0)
    field(:revision, :integer, default: 0)
    field(:metadata, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, @cast_fields)
    |> validate_required([:kind, :status, :source, :prompt, :tool_profile])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:tool_profile, @tool_profiles)
    |> validate_number(:attempt, greater_than: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_number(:last_event_sequence, greater_than_or_equal_to: 0)
  end

  @doc """
  Decode a Concord/store map into an `AgentRun`, applying defaults for fields
  absent from older stored values.
  """
  @spec from_store(map() | t()) :: t()
  def from_store(%__MODULE__{} = run), do: run

  def from_store(map) when is_map(map) do
    atomized = atomize_keys(map)

    %__MODULE__{
      id: Map.get(atomized, :id),
      kind: Map.get(atomized, :kind),
      status: Map.get(atomized, :status) || "queued",
      source: Map.get(atomized, :source) || "system",
      assistant_name: Map.get(atomized, :assistant_name),
      project_ref: Map.get(atomized, :project_ref),
      workspace_ref: Map.get(atomized, :workspace_ref),
      session_id: Map.get(atomized, :session_id),
      heartbeat_id: Map.get(atomized, :heartbeat_id),
      routine_id: Map.get(atomized, :routine_id),
      parent_run_id: Map.get(atomized, :parent_run_id),
      attempt: Map.get(atomized, :attempt) || 1,
      idempotency_key: Map.get(atomized, :idempotency_key),
      scheduled_for: Map.get(atomized, :scheduled_for),
      deadline_at: Map.get(atomized, :deadline_at),
      prompt: Map.get(atomized, :prompt),
      tool_profile: Map.get(atomized, :tool_profile) || "read_only",
      policy_snapshot: Map.get(atomized, :policy_snapshot) || %{},
      capability_snapshot: Map.get(atomized, :capability_snapshot) || %{},
      model: Map.get(atomized, :model),
      provider: Map.get(atomized, :provider),
      summary: Map.get(atomized, :summary),
      error: Map.get(atomized, :error),
      failure_class: Map.get(atomized, :failure_class),
      recovery_state: Map.get(atomized, :recovery_state) || %{},
      started_at: Map.get(atomized, :started_at),
      finished_at: Map.get(atomized, :finished_at),
      last_event_sequence: Map.get(atomized, :last_event_sequence) || 0,
      revision: Map.get(atomized, :revision) || 0,
      metadata: Map.get(atomized, :metadata) || %{},
      inserted_at: Map.get(atomized, :inserted_at),
      updated_at: Map.get(atomized, :updated_at)
    }
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @spec terminal?(t() | String.t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status) when is_binary(status), do: status in @terminal_statuses

  @spec to_store_map(t()) :: map()
  def to_store_map(%__MODULE__{} = run), do: Map.from_struct(run)

  defp atomize_keys(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, String.to_existing_atom(key), value)
      _, acc -> acc
    end)
  rescue
    ArgumentError ->
      Enum.reduce(map, %{}, fn
        {key, value}, acc when is_atom(key) ->
          Map.put(acc, key, value)

        {key, value}, acc when is_binary(key) ->
          case safe_existing_atom(key) do
            nil -> acc
            atom -> Map.put(acc, atom, value)
          end

        _, acc ->
          acc
      end)
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
