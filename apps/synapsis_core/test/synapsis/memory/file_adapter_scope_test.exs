defmodule Synapsis.Memory.FileAdapterScopeTest do
  use ExUnit.Case, async: false
  alias Synapsis.Memory.FileAdapter
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_MEMORY_DIR")
    System.put_env("SYNAPSIS_MEMORY_DIR", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_MEMORY_DIR", previous),
        else: System.delete_env("SYNAPSIS_MEMORY_DIR")
    end)

    %{root: root}
  end

  test "retriever scope pairs and candidate limits apply to list and search" do
    own = store("agent", "own")
    shared = store("shared", "")
    foreign = store("agent", "foreign")
    filters = [scopes: [{"agent", "own"}, {"shared", ""}], active: true]

    for results <- [FileAdapter.list(filters), FileAdapter.search("Concord", filters)] do
      assert MapSet.new(Enum.map(results, & &1.id)) == MapSet.new([own.id, shared.id])
      refute Enum.any?(results, &(&1.id == foreign.id))
    end

    assert length(FileAdapter.list(filters ++ [limit: 1])) == 1
    assert length(FileAdapter.search("Concord", filters ++ [limit: 1])) == 1
  end

  test "archive cannot report success when its persisted destination cannot be written", ctx do
    record = store("agent", "own")
    path = Path.join([ctx.root, "agent", "own", "#{record.id}.md"])
    File.write!(path, String.replace(File.read!(path), "scope: agent\n", "scope: blocked\n"))
    File.write!(Path.join(ctx.root, "blocked"), "prevents destination directory")
    assert {:error, _} = FileAdapter.archive(record.id)
    assert {:ok, %{archived_at: nil}} = FileAdapter.get(record.id)
  end

  test "legacy numeric plain-scalar IDs remain readable and archivable", ctx do
    for id <- ["9780855279746312", "0123456789012345", "1234567890123e45"] do
      record = store("shared", "")
      old_path = Path.join([ctx.root, "shared", "_global", "#{record.id}.md"])
      path = Path.join([ctx.root, "shared", "_global", "#{id}.md"])
      File.write!(path, Regex.replace(~r/^id: .*$/m, File.read!(old_path), "id: #{id}"))
      File.rm!(old_path)

      assert {:ok, %{id: ^id}} = FileAdapter.get(id)
      assert :ok = FileAdapter.archive(id)
      assert {:ok, %{id: ^id, archived_at: %DateTime{}}} = FileAdapter.get(id)
      refute Enum.any?(FileAdapter.search("Concord"), &(&1.id == id))
    end
  end

  defp store(scope, scope_id) do
    {:ok, record} =
      FileAdapter.store(%{
        scope: scope,
        scope_id: scope_id,
        kind: "fact",
        title: "Concord",
        summary: "Scoped memory",
        importance: 0.8
      })

    record
  end
end
