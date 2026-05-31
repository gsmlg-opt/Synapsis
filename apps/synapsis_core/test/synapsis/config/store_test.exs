defmodule Synapsis.Config.StoreTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Point the config dir at a temp directory for isolation.
    original = System.get_env("SYNAPSIS_CONFIG_DIR")
    System.put_env("SYNAPSIS_CONFIG_DIR", tmp_dir)

    on_exit(fn ->
      if original,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", original),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      # Reload all types from the now-empty tmp dir to reset ETS state.
      Enum.each(Store.types(), &Store.reload/1)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "list returns empty list when no file exists" do
    assert Store.list(:toolset) == []
  end

  test "put/get round-trips an entry" do
    entry = %{id: "t1", name: "default", tool_names: ["bash", "file_read"]}
    assert {:ok, saved} = Store.put(:toolset, entry)
    assert saved.id == "t1"
    assert saved.name == "default"

    assert {:ok, fetched} = Store.get(:toolset, "t1")
    assert fetched.id == "t1"
    assert fetched.name == "default"
  end

  test "put persists to TOML file" do
    Store.put(:toolset, %{id: "persisted", name: "persisted-set", tool_names: []})
    path = Store.file_path(:toolset)
    assert File.exists?(path)
    {:ok, content} = File.read(path)
    assert String.contains?(content, "persisted")
  end

  test "delete removes entry from ETS and persists" do
    Store.put(:toolset, %{id: "del-me", name: "to-delete", tool_names: []})
    assert {:ok, _} = Store.get(:toolset, "del-me")

    Store.delete(:toolset, "del-me")
    assert {:error, :not_found} = Store.get(:toolset, "del-me")
  end

  test "list returns all stored entries" do
    Store.put(:heartbeat, %{id: "h1", name: "daily", schedule: "0 9 * * *"})
    Store.put(:heartbeat, %{id: "h2", name: "weekly", schedule: "0 9 * * 1"})

    entries = Store.list(:heartbeat)
    ids = Enum.map(entries, & &1.id) |> Enum.sort()
    assert ids == ["h1", "h2"]
  end

  test "reload reads entries written directly to TOML file" do
    path = Store.file_path(:agent)
    File.mkdir_p!(Path.dirname(path))

    toml = """
    [[agents]]
    id = "file-agent"
    name = "from-file"
    provider = "anthropic"
    """

    File.write!(path, toml)
    Store.reload(:agent)

    assert {:ok, entry} = Store.get(:agent, "file-agent")
    assert entry.name == "from-file"
  end

  test "missing id returns error from put" do
    assert {:error, :missing_id} = Store.put(:toolset, %{name: "no-id"})
  end
end
