defmodule Synapsis.Heartbeats do
  @moduledoc """
  Context module for heartbeat configuration management.

  Provides the public API for heartbeat CRUD operations, delegating persistence
  to `Synapsis.HeartbeatConfig` in `synapsis_data`. Business logic such as
  scheduling and template seeding lives here, not in the schema module.
  """

  alias Synapsis.HeartbeatConfig

  @doc "Get a heartbeat config by ID."
  @spec get(String.t()) :: HeartbeatConfig.t() | nil
  defdelegate get(id), to: HeartbeatConfig

  @doc "Get a heartbeat config by name."
  @spec get_by_name(String.t()) :: HeartbeatConfig.t() | nil
  defdelegate get_by_name(name), to: HeartbeatConfig

  @doc "List all enabled heartbeat configs."
  @spec list_enabled() :: [HeartbeatConfig.t()]
  defdelegate list_enabled(), to: HeartbeatConfig

  @doc "List all heartbeat configs."
  @spec list_all() :: [HeartbeatConfig.t()]
  defdelegate list_all(), to: HeartbeatConfig

  @doc "Create a new heartbeat config with semantic cron validation."
  @spec create(map()) :: {:ok, HeartbeatConfig.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    case validate_cron_semantic(attrs) do
      :ok -> HeartbeatConfig.create(attrs)
      {:error, reason} -> {:error, cron_error_changeset(reason)}
    end
  end

  @doc "Update an existing heartbeat config with semantic cron validation."
  @spec update(HeartbeatConfig.t(), map()) ::
          {:ok, HeartbeatConfig.t()} | {:error, Ecto.Changeset.t()}
  def update(%HeartbeatConfig{} = config, attrs) do
    case validate_cron_semantic(attrs) do
      :ok -> HeartbeatConfig.update_config(config, attrs)
      {:error, reason} -> {:error, cron_error_changeset(reason)}
    end
  end

  @doc "Delete a heartbeat config."
  @spec delete(HeartbeatConfig.t()) :: {:ok, HeartbeatConfig.t()} | {:error, Ecto.Changeset.t()}
  def delete(%HeartbeatConfig{} = config) do
    HeartbeatConfig.delete_config(config)
  end

  @doc "Toggle enabled status and sync the scheduler."
  @spec toggle_enabled(HeartbeatConfig.t()) ::
          {:ok, HeartbeatConfig.t()} | {:error, Ecto.Changeset.t()}
  def toggle_enabled(%HeartbeatConfig{enabled: enabled} = config) do
    case HeartbeatConfig.update_config(config, %{enabled: not enabled}) do
      {:ok, updated} ->
        Synapsis.Agent.Heartbeat.Scheduler.sync_crontab()
        {:ok, updated}

      error ->
        error
    end
  end

  # Validates cron expression semantically using the Crontab parser.
  # Only validates if schedule is present in attrs.
  defp validate_cron_semantic(attrs) do
    schedule = attrs[:schedule] || attrs["schedule"]

    if is_binary(schedule) and String.trim(schedule) != "" do
      case Crontab.CronExpression.Parser.parse(schedule) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, "invalid cron syntax: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp cron_error_changeset(reason) do
    %HeartbeatConfig{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:schedule, reason)
  end
end
