defmodule Synapsis.Memory.FileAdapterTest do
  use ExUnit.Case, async: false

  alias Synapsis.Memory.FileAdapter

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # ADR-006 C4: FileAdapter ops are direct file I/O and read the memory dir
    # dynamically, so pointing the env at a tmp dir is all the isolation needed
    # (no process restart — that would race the supervisor).
    original = System.get_env("SYNAPSIS_MEMORY_DIR")
    System.put_env("SYNAPSIS_MEMORY_DIR", tmp_dir)

    on_exit(fn ->
      if original,
        do: System.put_env("SYNAPSIS_MEMORY_DIR", original),
        else: System.delete_env("SYNAPSIS_MEMORY_DIR")
    end)

    :ok
  end

  test "store and get a memory by id" do
    {:ok, m} =
      FileAdapter.store(%{
        scope: "agent",
        scope_id: "main",
        kind: "lesson",
        title: "Use Port for tools",
        summary: "Always use Port, never System.cmd.",
        tags: ["otp", "tools"],
        importance: 0.9
      })

    assert m.title == "Use Port for tools"
    assert m.scope == "agent"
    assert is_binary(m.id)

    assert {:ok, fetched} = FileAdapter.get(m.id)
    assert fetched.title == "Use Port for tools"
    assert fetched.summary == "Always use Port, never System.cmd."
  end

  test "store writes a Markdown file with YAML frontmatter" do
    {:ok, m} =
      FileAdapter.store(%{
        scope: "shared",
        scope_id: "",
        kind: "policy",
        title: "No secrets in logs",
        summary: "Never log API keys.",
        tags: ["security"],
        importance: 1.0
      })

    files = Path.wildcard(System.get_env("SYNAPSIS_MEMORY_DIR") <> "/**/*.md")
    assert Enum.any?(files, &String.contains?(&1, m.id))

    {:ok, content} = File.read(hd(Enum.filter(files, &String.contains?(&1, m.id))))
    assert String.contains?(content, "title: No secrets in logs")
    assert String.contains?(content, "Never log API keys.")
  end

  test "search by keyword returns matching memories" do
    FileAdapter.store(%{
      scope: "agent",
      scope_id: "x",
      kind: "fact",
      title: "ETS is fast",
      summary: "Use ETS for caches.",
      tags: [],
      importance: 0.7
    })

    FileAdapter.store(%{
      scope: "agent",
      scope_id: "x",
      kind: "fact",
      title: "GenServer bottleneck",
      summary: "Avoid single GenServer.",
      tags: [],
      importance: 0.6
    })

    results = FileAdapter.search("ETS cache", [])
    assert Enum.any?(results, &(&1.title == "ETS is fast"))
  end

  test "search by tag returns only tagged memories" do
    FileAdapter.store(%{
      scope: "shared",
      scope_id: "",
      kind: "lesson",
      title: "Supervision trees",
      summary: "Use supervisors.",
      tags: ["otp"],
      importance: 0.8
    })

    FileAdapter.store(%{
      scope: "shared",
      scope_id: "",
      kind: "lesson",
      title: "Ecto changeset",
      summary: "Use changesets.",
      tags: ["ecto"],
      importance: 0.7
    })

    results = FileAdapter.search("", tags: ["otp"])
    assert Enum.any?(results, &(&1.title == "Supervision trees"))
    refute Enum.any?(results, &(&1.title == "Ecto changeset"))
  end

  test "list returns all memories" do
    FileAdapter.store(%{
      scope: "agent",
      scope_id: "a",
      kind: "fact",
      title: "T1",
      summary: "s1",
      tags: [],
      importance: 0.5
    })

    FileAdapter.store(%{
      scope: "agent",
      scope_id: "a",
      kind: "fact",
      title: "T2",
      summary: "s2",
      tags: [],
      importance: 0.5
    })

    all = FileAdapter.list(scope: "agent", scope_id: "a")
    assert length(all) >= 2
  end

  test "update changes fields without losing others" do
    {:ok, m} =
      FileAdapter.store(%{
        scope: "shared",
        scope_id: "",
        kind: "fact",
        title: "Original",
        summary: "First version.",
        tags: [],
        importance: 0.5
      })

    {:ok, updated} = FileAdapter.update(m.id, %{title: "Updated title", importance: 0.9})
    assert updated.title == "Updated title"
    assert updated.importance == 0.9
    assert updated.summary == "First version."
  end

  test "search reads from disk even when the adapter process is down" do
    {:ok, m} =
      FileAdapter.store(%{
        scope: "agent",
        scope_id: "z",
        kind: "fact",
        title: "persisted memory",
        summary: "Should survive restart.",
        tags: ["restart"],
        importance: 0.5
      })

    # Stop the adapter process; direct file reads must still serve search.
    if pid = Process.whereis(FileAdapter), do: catch_exit(GenServer.stop(pid))

    results = FileAdapter.search("persisted", [])
    assert Enum.any?(results, &(&1.id == m.id))
  end

  test "archive removes memory from search results" do
    {:ok, m} =
      FileAdapter.store(%{
        scope: "shared",
        scope_id: "",
        kind: "fact",
        title: "to archive",
        summary: "Will be archived.",
        tags: ["temp"],
        importance: 0.5
      })

    assert :ok = FileAdapter.archive(m.id)
    results = FileAdapter.search("archive", [])
    refute Enum.any?(results, &(&1.id == m.id))
  end
end
