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

  @doc "Create a new heartbeat config."
  @spec create(map()) :: {:ok, HeartbeatConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create(attrs), to: HeartbeatConfig

  @doc "Update an existing heartbeat config."
  @spec update(HeartbeatConfig.t(), map()) ::
          {:ok, HeartbeatConfig.t()} | {:error, Ecto.Changeset.t()}
  def update(%HeartbeatConfig{} = config, attrs) do
    HeartbeatConfig.update_config(config, attrs)
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
end
