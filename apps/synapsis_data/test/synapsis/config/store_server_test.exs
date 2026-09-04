defmodule Synapsis.Config.Store.ServerTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Config.Store

  setup do
    clear_config_store(:provider)
    on_exit(fn -> clear_config_store(:provider) end)
    :ok
  end

  test "failed persistence leaves the published entry unchanged" do
    original = %{"id" => "provider-1", "name" => "Original"}
    updated = %{"id" => "provider-1", "name" => "Updated"}

    assert {:ok, ^original} = Store.put(:provider, original)

    path = Store.file_path(:provider)
    File.chmod!(path, 0o400)

    assert {:error, _reason} = Store.put(:provider, updated)
    assert {:ok, ^original} = Store.get(:provider, "provider-1")
  end

  test "failed delete persistence keeps the entry in ETS and on disk" do
    provider = %{"id" => "provider-1", "name" => "Original"}

    assert {:ok, ^provider} = Store.put(:provider, provider)

    path = Store.file_path(:provider)
    persisted = File.read!(path)
    File.chmod!(path, 0o400)

    assert {:error, {:persist_failed, _reason}} = Store.delete(:provider, "provider-1")
    assert {:ok, ^provider} = Store.get(:provider, "provider-1")
    assert File.read!(path) == persisted
  end

  test "successful delete removes the entry from ETS and disk" do
    provider = %{"id" => "provider-1", "name" => "Original"}

    assert {:ok, ^provider} = Store.put(:provider, provider)
    assert :ok = Store.delete(:provider, "provider-1")
    assert {:error, :not_found} = Store.get(:provider, "provider-1")

    assert :ok = Store.reload(:provider)
    assert {:error, :not_found} = Store.get(:provider, "provider-1")
  end

  test "merge-existing preserves stored fields and never recreates a concurrently deleted routine" do
    clear_config_store(:routine)
    on_exit(fn -> clear_config_store(:routine) end)

    id = Ecto.UUID.generate()

    routine = %{
      "id" => id,
      "name" => "user-owned-name",
      "kind" => "schedule",
      "enabled" => true,
      "schedule" => "* * * * *",
      "prompt" => "user-owned prompt"
    }

    assert {:ok, ^routine} = Store.put(:routine, routine)

    assert {:ok, merged} =
             Store.merge_existing(:routine, id, %{
               "id" => Ecto.UUID.generate(),
               "last_status" => "completed"
             })

    assert %{
             "id" => ^id,
             "name" => "user-owned-name",
             "prompt" => "user-owned prompt",
             "last_status" => "completed"
           } = merged

    for _iteration <- 1..10 do
      assert {:ok, _routine} = Store.put(:routine, routine)
      parent = self()

      delete =
        Task.async(fn ->
          receive do
            :go -> send(parent, {:delete_result, Store.delete(:routine, id)})
          end
        end)

      merge =
        Task.async(fn ->
          receive do
            :go ->
              send(
                parent,
                {:merge_result, Store.merge_existing(:routine, id, %{"next_run_at" => nil})}
              )
          end
        end)

      send(delete.pid, :go)
      send(merge.pid, :go)
      assert_receive {:delete_result, delete_result}
      assert_receive {:merge_result, merge_result}
      Task.await(delete)
      Task.await(merge)

      assert delete_result == :ok
      assert match?({:ok, _routine}, merge_result) or merge_result == {:error, :not_found}
      assert {:error, :not_found} = Store.get(:routine, id)
    end
  end

  test "malformed reload preserves the last known good entries" do
    provider = %{"id" => "provider-1", "name" => "Original"}
    assert {:ok, ^provider} = Store.put(:provider, provider)

    Store.file_path(:provider)
    |> File.write!("[[providers]]\nid =")

    assert {:error, {:parse_failed, _reason}} = Store.reload(:provider)
    assert {:ok, ^provider} = Store.get(:provider, "provider-1")
  end

  test "unreadable reload preserves the last known good entries" do
    provider = %{"id" => "provider-1", "name" => "Original"}
    assert {:ok, ^provider} = Store.put(:provider, provider)

    Store.file_path(:provider)
    |> File.chmod!(0o000)

    assert {:error, {:read_failed, :eacces}} = Store.reload(:provider)
    assert {:ok, ^provider} = Store.get(:provider, "provider-1")
  end

  test "invalid reload preserves the last known good entries" do
    clear_config_store(:routine)
    on_exit(fn -> clear_config_store(:routine) end)

    routine = %{
      "id" => Ecto.UUID.generate(),
      "name" => "valid-routine",
      "kind" => "schedule",
      "enabled" => true,
      "schedule" => "* * * * *",
      "prompt" => "Run safely"
    }

    assert {:ok, ^routine} = Store.put(:routine, routine)

    File.write!(
      Store.file_path(:routine),
      """
      [[routines]]
      id = "#{routine["id"]}"
      name = "invalid-routine"
      kind = "schedule"
      enabled = true
      schedule = "x x x x x"
      prompt = "Do not load"
      """
    )

    assert {:error, {:invalid_entry, {:invalid_routine, :schedule}}} =
             Store.reload(:routine)

    assert {:ok, ^routine} = Store.get(:routine, routine["id"])
  end

  test "successful reload replaces the live entries" do
    original = %{"id" => "provider-1", "name" => "Original"}
    replacement = %{"id" => "provider-2", "name" => "Replacement"}
    assert {:ok, ^original} = Store.put(:provider, original)

    File.write!(
      Store.file_path(:provider),
      """
      [[providers]]
      id = "provider-2"
      name = "Replacement"
      """
    )

    assert :ok = Store.reload(:provider)
    assert {:error, :not_found} = Store.get(:provider, "provider-1")
    assert {:ok, ^replacement} = Store.get(:provider, "provider-2")
  end
end
