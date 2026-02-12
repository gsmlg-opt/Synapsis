defmodule Synapsis.FileWatcher do
  @moduledoc "Watches project directories for file changes and broadcasts events."
  use GenServer
  require Logger

  def start_link(opts) do
    project_path = Keyword.fetch!(opts, :project_path)
    GenServer.start_link(__MODULE__, opts, name: via(project_path))
  end

  def stop(project_path) do
    case Registry.lookup(Synapsis.FileWatcher.Registry, project_path) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> :ok
    end
  end

  defp via(project_path) do
    {:via, Registry, {Synapsis.FileWatcher.Registry, project_path}}
  end

  @impl true
  def init(opts) do
    project_path = Keyword.fetch!(opts, :project_path)

    case file_system_available?() do
      true ->
        {:ok, pid} = FileSystem.start_link(dirs: [project_path])
        FileSystem.subscribe(pid)
        Logger.info("file_watcher_started", project_path: project_path)
        {:ok, %{project_path: project_path, fs_pid: pid}}

      false ->
        Logger.info("file_watcher_unavailable", project_path: project_path)
        {:ok, %{project_path: project_path, fs_pid: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    unless ignored?(path) do
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "file_changes:#{state.project_path}",
        {:file_changed, path, events}
      )
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.info("file_watcher_stopped", project_path: state.project_path)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{fs_pid: pid}) when not is_nil(pid) do
    Process.exit(pid, :normal)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp ignored?(path) do
    ignore_patterns = [
      ~r/\/_build\//,
      ~r/\/deps\//,
      ~r/\/node_modules\//,
      ~r/\/\.git\//,
      ~r/\/\.elixir_ls\//,
      ~r/\.beam$/,
      ~r/\.pyc$/
    ]

    Enum.any?(ignore_patterns, &Regex.match?(&1, path))
  end

  defp file_system_available? do
    Code.ensure_loaded?(FileSystem)
  end
end
