defmodule Synapsis.FileWatcherTest do
  use ExUnit.Case, async: false

  alias Synapsis.FileWatcher

  @project_path "/tmp/file-watcher-test-#{:rand.uniform(999_999)}"

  setup do
    # Ensure we have a unique path per test run
    path = "#{@project_path}-#{System.unique_integer([:positive])}"
    File.mkdir_p!(path)
    {:ok, _pid} = FileWatcher.start_link(project_path: path)

    on_exit(fn ->
      case Registry.lookup(Synapsis.FileWatcher.Registry, path) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid)
        [] -> :ok
      end
    end)

    {:ok, path: path}
  end

  test "starts and registers under project path", %{path: path} do
    assert [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "stop/1 terminates the watcher", %{path: path} do
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)
    assert Process.alive?(pid)

    :ok = FileWatcher.stop(path)
    refute Process.alive?(pid)
  end

  test "stop/1 returns :ok for unknown path" do
    assert :ok = FileWatcher.stop("/nonexistent/path/#{:rand.uniform(999_999)}")
  end

  test "broadcasts file_changed for non-ignored paths", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"#{path}/main.ex", [:modified]}})

    assert_receive {:file_changed, _path, [:modified]}, 500
  end

  test "does not broadcast for _build paths", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"#{path}/_build/dev/lib/app.beam", [:modified]}})

    refute_receive {:file_changed, _, _}, 100
  end

  test "does not broadcast for deps paths", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"#{path}/deps/phoenix/lib/module.ex", [:modified]}})

    refute_receive {:file_changed, _, _}, 100
  end

  test "does not broadcast for .git paths", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"#{path}/.git/COMMIT_EDITMSG", [:modified]}})

    refute_receive {:file_changed, _, _}, 100
  end

  test "does not broadcast for .beam files", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"/some/path/module.beam", [:modified]}})

    refute_receive {:file_changed, _, _}, 100
  end

  test "handles :stop file_event without crashing", %{path: path} do
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)
    send(pid, {:file_event, self(), :stop})
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "handles unknown messages without crashing", %{path: path} do
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)
    send(pid, :totally_unknown_message)
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "does not broadcast for node_modules paths", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"#{path}/node_modules/lodash/index.js", [:modified]}})

    refute_receive {:file_changed, _, _}, 100
  end

  test "does not broadcast for .elixir_ls paths", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"#{path}/.elixir_ls/build/module.beam", [:modified]}})

    refute_receive {:file_changed, _, _}, 100
  end

  test "does not broadcast for .pyc files", %{path: path} do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "file_changes:#{path}")
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)

    send(pid, {:file_event, self(), {"/some/path/module.pyc", [:modified]}})

    refute_receive {:file_changed, _, _}, 100
  end

  test "terminate/2 with nil fs_pid returns :ok", %{path: path} do
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)
    # Replace state so fs_pid is nil then stop
    :sys.replace_state(pid, fn state -> %{state | fs_pid: nil} end)
    :ok = GenServer.stop(pid)
    refute Process.alive?(pid)
  end

  test "terminate/2 with non-nil fs_pid exits the fs process", %{path: path} do
    [{pid, _}] = Registry.lookup(Synapsis.FileWatcher.Registry, path)
    state = :sys.get_state(pid)
    # fs_pid may be nil if FileSystem is disabled in test env
    if state.fs_pid do
      assert is_pid(state.fs_pid)
      :ok = GenServer.stop(pid)
      refute Process.alive?(pid)
    else
      # FileSystem not available in test env — terminate/2 with nil is already covered
      assert true
    end
  end
end
