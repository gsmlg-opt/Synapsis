defmodule Synapsis.Config.Store.Watcher do
  @moduledoc """
  FileSystem watcher that triggers a config reload when any TOML config file changes.
  """

  use GenServer
  require Logger

  alias Synapsis.Config.Store

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    dir = Store.config_dir()

    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("config_watcher_mkdir", path: dir, reason: inspect(reason))
    end

    # file_system watches the directory; events are sent to this process.
    case FileSystem.start_link(dirs: [dir], name: :synapsis_config_fs) do
      {:ok, pid} ->
        FileSystem.subscribe(:synapsis_config_fs)
        {:ok, %{watcher_pid: pid, dir: dir}}

      {:error, reason} ->
        Logger.warning("config_watcher_start_failed", reason: inspect(reason))
        {:ok, %{watcher_pid: nil, dir: dir}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    case type_for_path(path) do
      nil -> :ok
      type -> Store.reload(type)
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp type_for_path(path) do
    Enum.find(Store.types(), fn type ->
      Store.file_path(type) == path
    end)
  end
end
