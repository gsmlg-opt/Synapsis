defmodule Synapsis.Workspace.WorkspacePathAliasFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Workspace
  alias Synapsis.Workspace.FileDocuments

  @moduletag :tmp_dir

  # Independent ordinary compatibility expectations from the batch206 before/
  # snapshots and PathResolver.normalize_path/1, frozen before the alias repair.
  # Storage/resource paths normalize slashes. Existing public write/move events
  # retain caller spelling; delete events use the canonical stored document path.
  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    %{root: root}
  end

  test "public writes normalize repeated and trailing slashes while preserving caller event paths",
       %{root: root} do
    create_path = "/shared//alias.txt"
    update_path = "/shared/alias.txt/"
    canonical = "/shared/alias.txt"

    assert {:ok, first} =
             Workspace.write(create_path, "first", %{
               author: "creator",
               metadata: %{label: "keep"}
             })

    assert first.path == canonical and first.content == "first" and first.version == 1
    assert first.id == "ab5967e81f47d6790c4d1d80e4d256c9"
    assert first.created_by == "creator" and first.updated_by == "creator"
    assert_receive {:workspace_changed, %{path: ^create_path, action: :created, resource_id: id}}
    assert first.id == id

    assert {:ok, second} = Workspace.write(update_path, "second", %{author: "updater"})
    assert second.path == canonical and second.content == "second" and second.version == 2
    assert second.id == id and second.metadata == %{label: "keep"}
    assert second.created_by == "creator" and second.updated_by == "updater"
    assert_receive {:workspace_changed, %{path: ^update_path, action: :updated, resource_id: ^id}}
    assert {:ok, by_id} = Workspace.read(id)
    assert by_id.path == canonical and by_id.content == "second" and by_id.version == 2
    assert File.read!(Path.join(root, "shared/alias.txt")) == "second"
    assert File.ls!(Path.join(root, ".synapsis/meta")) == ["shared__alias.txt.json"]
    metadata = Jason.decode!(File.read!(Path.join(root, ".synapsis/meta/shared__alias.txt.json")))
    assert metadata["path"] == canonical and metadata["id"] == id and metadata["version"] == 2
    assert metadata["metadata"] == %{"label" => "keep"}
    refute_receive {:workspace_changed, _}, 0
  end

  test "public path deletion accepts a slash alias and publishes the canonical stored path", %{
    root: root
  } do
    canonical = "/shared/delete.txt"
    assert {:ok, resource} = Workspace.write(canonical, "delete body", %{author: "creator"})
    id = resource.id
    assert id == "fea3638c4283b0a385b01871653a90e9"
    assert_receive {:workspace_changed, %{path: ^canonical, action: :created, resource_id: ^id}}

    assert :ok = Workspace.delete("/shared//delete.txt/")
    assert_receive {:workspace_changed, %{path: ^canonical, action: :deleted, resource_id: ^id}}
    assert File.ls!(Path.join(root, "shared")) == []
    assert File.ls!(Path.join(root, ".synapsis/meta")) == []
    refute_receive {:workspace_changed, _}, 0
  end

  test "public move normalizes both alias keys and preserves copy semantics ID metadata and event spelling",
       %{root: root} do
    source = "/shared/source.txt"
    destination = "/shared/copied.txt"
    source_alias = "/shared//source.txt/"
    destination_alias = "/shared///copied.txt/"

    assert {:ok, original} =
             Workspace.write(source, "copy body", %{author: "creator", metadata: %{label: "keep"}})

    id = original.id
    assert id == "c8dbf3323da869bccd2a5fb295374947"
    assert_receive {:workspace_changed, %{path: ^source, action: :created, resource_id: ^id}}

    assert {:ok, copied} = Workspace.move(source_alias, destination_alias)
    assert copied.path == destination and copied.content == "copy body"
    assert copied.id == id and copied.version == 1 and copied.metadata == %{label: "keep"}
    assert copied.created_by == "creator" and copied.updated_by == "creator"

    assert_receive {:workspace_changed,
                    %{path: ^source_alias, action: :deleted, resource_id: ^id}}

    assert_receive {:workspace_changed,
                    %{path: ^destination_alias, action: :created, resource_id: ^id}}

    assert File.read!(Path.join(root, "shared/source.txt")) == "copy body"
    assert File.read!(Path.join(root, "shared/copied.txt")) == "copy body"

    assert {:ok, %{path: ^source, id: ^id, version: 1, content_body: "copy body"}} =
             FileDocuments.get(root, source)

    assert {:ok, %{path: ^destination, id: ^id, version: 1, content_body: "copy body"}} =
             FileDocuments.get(root, destination)

    assert Enum.sort(File.ls!(Path.join(root, ".synapsis/meta"))) == [
             "shared__copied.txt.json",
             "shared__source.txt.json"
           ]

    # The legacy copy leaves duplicate IDs until one path is removed. Resolve
    # the remaining unambiguous ID only after deleting the destination normally.
    assert :ok = Workspace.delete(destination)
    assert_receive {:workspace_changed, %{path: ^destination, action: :deleted, resource_id: ^id}}
    assert {:ok, retained} = Workspace.read(id)
    assert retained.path == source and retained.content == "copy body"
    assert retained.metadata == %{label: "keep"}
    assert :ok = Workspace.delete(id)
    assert_receive {:workspace_changed, %{path: ^source, action: :deleted, resource_id: ^id}}
    assert File.ls!(Path.join(root, "shared")) == []
    assert File.ls!(Path.join(root, ".synapsis/meta")) == []
    refute_receive {:workspace_changed, _}, 0
  end
end
