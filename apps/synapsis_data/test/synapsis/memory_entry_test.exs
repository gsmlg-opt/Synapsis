defmodule Synapsis.MemoryEntryTest do
  use Synapsis.DataCase

  alias Synapsis.{MemoryEntry, Repo}

  describe "changeset/2" do
    test "valid with required fields" do
      cs = %MemoryEntry{} |> MemoryEntry.changeset(%{scope: "global", key: "test", content: "value"})
      assert cs.valid?
    end

    test "invalid without scope" do
      cs = %MemoryEntry{} |> MemoryEntry.changeset(%{key: "test", content: "value"})
      refute cs.valid?
      assert %{scope: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without key" do
      cs = %MemoryEntry{} |> MemoryEntry.changeset(%{scope: "global", content: "value"})
      refute cs.valid?
      assert %{key: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without content" do
      cs = %MemoryEntry{} |> MemoryEntry.changeset(%{scope: "global", key: "test"})
      refute cs.valid?
      assert %{content: ["can't be blank"]} = errors_on(cs)
    end

    test "validates scope inclusion" do
      cs = %MemoryEntry{} |> MemoryEntry.changeset(%{scope: "invalid", key: "k", content: "c"})
      refute cs.valid?
      assert %{scope: [_]} = errors_on(cs)
    end

    test "allows valid scopes" do
      for scope <- ~w(global project session) do
        cs = %MemoryEntry{} |> MemoryEntry.changeset(%{scope: scope, key: "k", content: "c"})
        assert cs.valid?, "Expected scope #{scope} to be valid"
      end
    end

    test "sets default metadata" do
      cs = %MemoryEntry{} |> MemoryEntry.changeset(%{scope: "global", key: "k", content: "c"})
      assert get_field(cs, :metadata) == %{}
    end
  end

  describe "persistence" do
    test "inserts and retrieves entry" do
      {:ok, entry} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{scope: "global", key: "test-key", content: "test-value"})
        |> Repo.insert()

      found = Repo.get!(MemoryEntry, entry.id)
      assert found.key == "test-key"
      assert found.content == "test-value"
      assert found.scope == "global"
    end

    test "allows duplicate scope+key when scope_id is NULL (NULL is distinct)" do
      # PostgreSQL treats NULL as distinct in unique indexes
      attrs = %{scope: "global", key: "unique-key", content: "value"}

      {:ok, _} = %MemoryEntry{} |> MemoryEntry.changeset(attrs) |> Repo.insert()
      {:ok, _} = %MemoryEntry{} |> MemoryEntry.changeset(attrs) |> Repo.insert()
    end

    test "enforces unique constraint when scope_id is set" do
      scope_id = Ecto.UUID.generate()
      attrs = %{scope: "project", scope_id: scope_id, key: "unique-key", content: "value"}

      {:ok, _} = %MemoryEntry{} |> MemoryEntry.changeset(attrs) |> Repo.insert()

      {:error, cs} = %MemoryEntry{} |> MemoryEntry.changeset(attrs) |> Repo.insert()
      assert %{scope: ["has already been taken"]} = errors_on(cs)
    end
  end
end
