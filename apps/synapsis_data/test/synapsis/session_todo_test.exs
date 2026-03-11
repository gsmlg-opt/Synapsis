defmodule Synapsis.SessionTodoTest do
  use Synapsis.DataCase

  alias Synapsis.SessionTodo

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        todo_id: "task-1",
        content: "Implement feature X"
      }

      changeset = SessionTodo.changeset(%SessionTodo{}, attrs)
      assert changeset.valid?
    end

    test "invalid without session_id" do
      attrs = %{todo_id: "task-1", content: "Do something"}
      changeset = SessionTodo.changeset(%SessionTodo{}, attrs)
      refute changeset.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without todo_id" do
      attrs = %{session_id: Ecto.UUID.generate(), content: "Do something"}
      changeset = SessionTodo.changeset(%SessionTodo{}, attrs)
      refute changeset.valid?
      assert %{todo_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without content" do
      attrs = %{session_id: Ecto.UUID.generate(), todo_id: "task-1"}
      changeset = SessionTodo.changeset(%SessionTodo{}, attrs)
      refute changeset.valid?
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates todo_id max length" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        todo_id: String.duplicate("a", 256),
        content: "Test"
      }

      changeset = SessionTodo.changeset(%SessionTodo{}, attrs)
      refute changeset.valid?
    end

    test "accepts optional fields" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        todo_id: "task-2",
        content: "Write tests",
        status: :in_progress,
        sort_order: 5
      }

      changeset = SessionTodo.changeset(%SessionTodo{}, attrs)
      assert changeset.valid?
    end

    test "defaults are correct" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        todo_id: "task-1",
        content: "Do thing"
      }

      changeset = SessionTodo.changeset(%SessionTodo{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == :pending
      assert Ecto.Changeset.get_field(changeset, :sort_order) == 0
    end
  end
end
