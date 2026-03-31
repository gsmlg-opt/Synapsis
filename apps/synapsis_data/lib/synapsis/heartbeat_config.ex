defmodule Synapsis.HeartbeatConfig do
  @moduledoc """
  Schema for heartbeat configuration (AI-6).

  Heartbeats are scheduled agent invocations that run via Oban cron jobs.
  Each config defines a schedule, prompt, and behavior for proactive execution.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "heartbeat_configs" do
    field(:name, :string)
    field(:schedule, :string)
    field(:agent_type, Ecto.Enum, values: [:global, :project])
    field(:prompt, :string)
    field(:enabled, :boolean, default: false)
    field(:notify_user, :boolean, default: true)
    field(:session_isolation, Ecto.Enum, values: [:isolated, :main], default: :isolated)
    field(:keep_history, :boolean, default: false)

    belongs_to(:project, Synapsis.Project)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :name,
      :schedule,
      :agent_type,
      :project_id,
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
    |> unique_constraint(:name)
  end

  # -- Context API --

  @doc "Get a heartbeat config by ID."
  @spec get(String.t()) :: t() | nil
  def get(id), do: Synapsis.Repo.get(__MODULE__, id)

  @doc "Get a heartbeat config by name."
  @spec get_by_name(String.t()) :: t() | nil
  def get_by_name(name), do: Synapsis.Repo.get_by(__MODULE__, name: name)

  @doc "List all enabled heartbeat configs."
  @spec list_enabled() :: [t()]
  def list_enabled do
    __MODULE__
    |> where([c], c.enabled == true)
    |> Synapsis.Repo.all()
  end

  @doc "List all heartbeat configs."
  @spec list_all() :: [t()]
  def list_all do
    __MODULE__
    |> order_by([c], asc: c.name)
    |> Synapsis.Repo.all()
  end

  @doc "Insert a new heartbeat config."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Synapsis.Repo.insert()
  end

  @doc "Update an existing heartbeat config."
  @spec update_config(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_config(%__MODULE__{} = config, attrs) do
    config
    |> changeset(attrs)
    |> Synapsis.Repo.update()
  end

  @doc "Delete a heartbeat config."
  @spec delete_config(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def delete_config(%__MODULE__{} = config) do
    Synapsis.Repo.delete(config)
  end

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
