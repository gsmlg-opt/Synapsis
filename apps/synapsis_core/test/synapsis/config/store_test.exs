defmodule Synapsis.Config.StoreTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Point the config dir at a temp directory and isolate the live ETS cache.
    original = System.get_env("SYNAPSIS_CONFIG_DIR")
    original_entries = snapshot_entries()
    System.put_env("SYNAPSIS_CONFIG_DIR", tmp_dir)
    replace_entries(%{})

    on_exit(fn ->
      if original,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", original),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      replace_entries(original_entries)
    end)

    %{tmp_dir: tmp_dir}
  end

  defp snapshot_entries do
    Map.new(Store.types(), fn type -> {type, :ets.tab2list(table(type))} end)
  end

  defp replace_entries(entries) do
    Enum.each(Store.types(), fn type ->
      table = table(type)
      :ets.delete_all_objects(table)

      case Map.get(entries, type, []) do
        [] -> :ok
        values -> :ets.insert(table, values)
      end
    end)
  end

  defp table(type), do: :"synapsis_config_#{type}"

  test "list returns empty list when no file exists" do
    assert Store.list(:toolset) == []
  end

  test "put/get round-trips an entry" do
    entry = %{id: "t1", name: "default", tool_names: ["bash", "file_read"]}
    assert {:ok, saved} = Store.put(:toolset, entry)
    assert saved["id"] == "t1"
    assert saved["name"] == "default"

    assert {:ok, fetched} = Store.get(:toolset, "t1")
    assert fetched["id"] == "t1"
    assert fetched["name"] == "default"
  end

  test "put persists to TOML file" do
    Store.put(:toolset, %{id: "persisted", name: "persisted-set", tool_names: []})
    path = Store.file_path(:toolset)
    assert File.exists?(path)
    {:ok, content} = File.read(path)
    assert String.contains?(content, "persisted")
  end

  test "put omits empty map fields so entries reload with their ids" do
    Store.put(:provider, %{id: "p1", name: "provider-one", type: "anthropic", config: %{}})

    path = Store.file_path(:provider)
    assert File.read!(path) =~ ~s(id = "p1")
    refute File.read!(path) =~ "config = {}"

    Store.reload(:provider)
    assert {:ok, entry} = Store.get(:provider, "p1")
    assert entry["name"] == "provider-one"
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
    ids = Enum.map(entries, & &1["id"]) |> Enum.sort()
    assert ids == ["h1", "h2"]
  end

  test "routine configs round-trip through routines.toml" do
    routine = %{
      id: "daily-reflection",
      name: "daily reflection",
      kind: "dream",
      enabled: true,
      schedule: "0 21 * * *",
      prompt: "reflect",
      no_overlap: true,
      max_runtime_ms: 60_000
    }

    assert {:ok, saved} = Store.put(:routine, routine)
    assert saved["kind"] == "dream"
    assert Store.file_path(:routine) |> File.read!() =~ "[[routines]]"

    Store.reload(:routine)
    assert {:ok, fetched} = Store.get(:routine, "daily-reflection")
    assert fetched["max_runtime_ms"] == 60_000
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
    assert entry["name"] == "from-file"
  end

  test "missing id returns error from put" do
    assert {:error, :missing_id} = Store.put(:toolset, %{name: "no-id"})
  end
end
