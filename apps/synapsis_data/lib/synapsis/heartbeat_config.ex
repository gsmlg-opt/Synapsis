defmodule Synapsis.HeartbeatConfig do
  @moduledoc """
  Heartbeat configuration — scheduled agent invocations.

  ADR-006 C4: an `embedded_schema` (no DB table). Heartbeat configs persist in
  the file-backed `Config.Store` (`heartbeats.toml`). The scheduler is the
  node-local cron (`Synapsis.Agent.Heartbeat.LocalScheduler`), not Oban.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Synapsis.Config.Store

  @type t :: %__MODULE__{}
  @store_type :heartbeat

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  embedded_schema do
    field(:name, :string)
    field(:schedule, :string)
    field(:agent_type, Ecto.Enum, values: [:global, :agent])
    field(:agent_name, :string)
    field(:prompt, :string)
    field(:enabled, :boolean, default: false)
    field(:notify_user, :boolean, default: true)
    field(:session_isolation, Ecto.Enum, values: [:isolated, :main], default: :isolated)
    field(:keep_history, :boolean, default: false)

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :id,
      :name,
      :schedule,
      :agent_type,
      :agent_name,
      :prompt,
      :enabled,
      :notify_user,
      :session_isolation,
      :keep_history
    ])
    |> validate_required([:name, :schedule, :prompt])
    |> validate_length(:name, max: 255)
    |> validate_length(:schedule, max: 255)
    |> validate_length(:prompt, max: 50_000)
    |> validate_cron_expression(:schedule)
  end

  # ── Context API (Config.Store-backed) ──────────────────────────────────────

  @spec get(String.t()) :: t() | nil
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  @spec get_by_name(String.t()) :: t() | nil
  def get_by_name(name), do: Enum.find(list_all(), &(&1.name == name))

  @spec list_enabled() :: [t()]
  def list_enabled, do: Enum.filter(list_all(), & &1.enabled)

  @spec list_all() :: [t()]
  def list_all do
    @store_type
    |> Store.list()
    |> Enum.map(&to_struct/1)
    |> Enum.sort_by(& &1.name)
  end

  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    changeset = changeset(%__MODULE__{}, attrs)

    if changeset.valid? do
      record = changeset |> apply_changes() |> ensure_id()

      case Store.put(@store_type, to_store_map(record)) do
        :ok -> {:ok, record}
        {:ok, _} -> {:ok, record}
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  @spec update_config(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_config(%__MODULE__{} = config, attrs) do
    changeset = changeset(config, attrs)

    if changeset.valid? do
      record = apply_changes(changeset)

      case Store.put(@store_type, to_store_map(record)) do
        :ok -> {:ok, record}
        {:ok, _} -> {:ok, record}
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  @spec delete_config(t()) :: :ok
  def delete_config(%__MODULE__{id: id}), do: Store.delete(@store_type, id)

  # ── internals ──────────────────────────────────────────────────────────────

  defp ensure_id(%__MODULE__{id: nil} = record), do: %{record | id: Ecto.UUID.generate()}
  defp ensure_id(record), do: record

  # Build a struct from a Config.Store string-keyed map; cast handles enums.
  defp to_struct(map) do
    %__MODULE__{} |> changeset(map) |> apply_changes() |> set_id(map)
  end

  defp set_id(record, map), do: %{record | id: map["id"] || record.id}

  # Convert a struct to a flat string-keyed map for TOML persistence.
  defp to_store_map(%__MODULE__{} = record) do
    %{
      "id" => record.id,
      "name" => record.name,
      "schedule" => record.schedule,
      "agent_type" => to_string_or_nil(record.agent_type),
      "agent_name" => record.agent_name,
      "prompt" => record.prompt,
      "enabled" => record.enabled,
      "notify_user" => record.notify_user,
      "session_isolation" => to_string_or_nil(record.session_isolation),
      "keep_history" => record.keep_history
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(atom), do: Atom.to_string(atom)

  defp validate_cron_expression(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      parts = String.split(value, " ", trim: true)

      if length(parts) != 5 do
        [{field, "must be a valid cron expression with 5 fields"}]
      else
        []
      end
    end)
  end
end
