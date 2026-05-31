defmodule Synapsis.Workspace.FileDocumentsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.FileDocuments

  @moduletag :tmp_dir

  test "get returns not_found for missing file", %{tmp_dir: dir} do
    assert {:error, :not_found} = FileDocuments.get(dir, "missing.md")
  end

  test "put writes content and get reads it back", %{tmp_dir: dir} do
    assert {:ok, doc} = FileDocuments.put(dir, %{path: "notes.md", content_body: "hello"})
    assert doc.content_body == "hello"
    assert doc.path == "notes.md"
    assert doc.version == 1

    assert {:ok, fetched} = FileDocuments.get(dir, "notes.md")
    assert fetched.content_body == "hello"
  end

  test "put increments version on update", %{tmp_dir: dir} do
    FileDocuments.put(dir, %{path: "doc.md", content_body: "v1"})
    {:ok, v2} = FileDocuments.put(dir, %{path: "doc.md", content_body: "v2"})
    assert v2.version == 2
  end

  test "delete removes file and metadata", %{tmp_dir: dir} do
    FileDocuments.put(dir, %{path: "temp.md", content_body: "bye"})
    assert {:ok, _} = FileDocuments.get(dir, "temp.md")

    FileDocuments.delete(dir, "temp.md")
    assert {:error, :not_found} = FileDocuments.get(dir, "temp.md")
  end

  test "list returns all documents in the workspace", %{tmp_dir: dir} do
    FileDocuments.put(dir, %{path: "a.md", content_body: "a"})
    FileDocuments.put(dir, %{path: "b.md", content_body: "b"})

    docs = FileDocuments.list(dir)
    paths = Enum.map(docs, & &1.path) |> Enum.sort()
    assert paths == ["a.md", "b.md"]
  end

  test "list excludes .synapsis metadata directory", %{tmp_dir: dir} do
    FileDocuments.put(dir, %{path: "real.md", content_body: "content"})
    docs = FileDocuments.list(dir)
    refute Enum.any?(docs, &String.starts_with?(&1.path, ".synapsis"))
  end

  test "infers markdown format from .md extension", %{tmp_dir: dir} do
    {:ok, doc} = FileDocuments.put(dir, %{path: "note.md", content_body: ""})
    assert doc.content_format == "markdown"
  end

  test "metadata persists across get calls", %{tmp_dir: dir} do
    FileDocuments.put(dir, %{
      path: "meta.md",
      content_body: "x",
      kind: "handoff",
      visibility: "agent_shared"
    })

    {:ok, doc} = FileDocuments.get(dir, "meta.md")
    assert doc.kind == "handoff"
    assert doc.visibility == "agent_shared"
  end
end
