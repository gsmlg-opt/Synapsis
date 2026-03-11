defmodule Synapsis.Tool.TodoTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Tool.{TodoWrite, TodoRead}

  setup do
    # Create project and session for FK constraints
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/todo_test", slug: "todo-test"})
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "test",
        model: "test-model"
      })
      |> Repo.insert()

    %{session: session, project: project}
  end

  describe "TodoWrite" do
    test "has correct metadata" do
      assert TodoWrite.name() == "todo_write"
      assert TodoWrite.permission_level() == :none
      assert TodoWrite.category() == :planning
      assert is_binary(TodoWrite.description())
      assert %{"type" => "object"} = TodoWrite.parameters()
    end

    test "writes todos for a session", %{session: session} do
      todos = [
        %{"id" => "1", "content" => "First task", "status" => "pending"},
        %{"id" => "2", "content" => "Second task", "status" => "in_progress"}
      ]

      assert {:ok, msg} = TodoWrite.execute(%{"todos" => todos}, %{session_id: session.id})
      assert msg =~ "2 todo(s)"

      # Verify persisted
      stored =
        from(t in Synapsis.SessionTodo,
          where: t.session_id == ^session.id,
          order_by: [asc: t.sort_order]
        )
        |> Repo.all()

      assert length(stored) == 2
      assert Enum.at(stored, 0).todo_id == "1"
      assert Enum.at(stored, 0).content == "First task"
      assert Enum.at(stored, 0).status == :pending
      assert Enum.at(stored, 0).sort_order == 0
      assert Enum.at(stored, 1).todo_id == "2"
      assert Enum.at(stored, 1).status == :in_progress
      assert Enum.at(stored, 1).sort_order == 1
    end

    test "replaces full list on subsequent write", %{session: session} do
      first = [
        %{"id" => "a", "content" => "Old task", "status" => "pending"}
      ]

      assert {:ok, _} = TodoWrite.execute(%{"todos" => first}, %{session_id: session.id})

      second = [
        %{"id" => "b", "content" => "New task", "status" => "completed"},
        %{"id" => "c", "content" => "Another", "status" => "pending"}
      ]

      assert {:ok, msg} = TodoWrite.execute(%{"todos" => second}, %{session_id: session.id})
      assert msg =~ "2 todo(s)"

      stored =
        from(t in Synapsis.SessionTodo, where: t.session_id == ^session.id)
        |> Repo.all()

      assert length(stored) == 2
      ids = Enum.map(stored, & &1.todo_id) |> Enum.sort()
      assert ids == ["b", "c"]
    end

    test "handles empty list", %{session: session} do
      # First write some todos
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending"}]
      assert {:ok, _} = TodoWrite.execute(%{"todos" => todos}, %{session_id: session.id})

      # Then clear them
      assert {:ok, msg} = TodoWrite.execute(%{"todos" => []}, %{session_id: session.id})
      assert msg =~ "0 todo(s)"

      stored =
        from(t in Synapsis.SessionTodo, where: t.session_id == ^session.id)
        |> Repo.all()

      assert stored == []
    end

    test "broadcasts todo_update on write", %{session: session} do
      topic = "session:#{session.id}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)

      todos = [%{"id" => "1", "content" => "Task", "status" => "pending"}]
      assert {:ok, _} = TodoWrite.execute(%{"todos" => todos}, %{session_id: session.id})

      session_id = session.id
      assert_receive {:todo_update, ^session_id, inserted_todos}
      assert length(inserted_todos) == 1
      assert hd(inserted_todos).todo_id == "1"
    end

    test "returns error without session_id" do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending"}]
      assert {:error, msg} = TodoWrite.execute(%{"todos" => todos}, %{})
      assert msg =~ "session_id"
    end
  end

  describe "TodoRead" do
    test "has correct metadata" do
      assert TodoRead.name() == "todo_read"
      assert TodoRead.permission_level() == :none
      assert TodoRead.category() == :planning
      assert is_binary(TodoRead.description())
      assert %{"type" => "object"} = TodoRead.parameters()
    end

    test "reads current ordered todos", %{session: session} do
      todos = [
        %{"id" => "1", "content" => "First", "status" => "pending"},
        %{"id" => "2", "content" => "Second", "status" => "completed"},
        %{"id" => "3", "content" => "Third", "status" => "in_progress"}
      ]

      assert {:ok, _} = TodoWrite.execute(%{"todos" => todos}, %{session_id: session.id})

      assert {:ok, result} = TodoRead.execute(%{}, %{session_id: session.id})

      # Result may be a list of maps or a JSON string depending on implementation
      parsed =
        case result do
          str when is_binary(str) ->
            Jason.decode!(str)

          list when is_list(list) ->
            Enum.map(list, fn m -> Map.new(m, fn {k, v} -> {to_string(k), v} end) end)
        end

      assert length(parsed) == 3
      assert Enum.at(parsed, 0)["id"] == "1"
      assert Enum.at(parsed, 1)["id"] == "2"
      assert Enum.at(parsed, 2)["id"] == "3"
      assert Enum.at(parsed, 0)["status"] == "pending"
      assert Enum.at(parsed, 1)["status"] == "completed"
      assert Enum.at(parsed, 2)["status"] == "in_progress"
    end

    test "returns empty list when no todos exist", %{session: session} do
      assert {:ok, result} = TodoRead.execute(%{}, %{session_id: session.id})

      parsed =
        case result do
          str when is_binary(str) -> Jason.decode!(str)
          list when is_list(list) -> list
        end

      assert parsed == []
    end

    test "returns ok with empty result without session_id" do
      # Linter version returns {:ok, []} for nil session
      assert {:ok, result} = TodoRead.execute(%{}, %{})

      parsed =
        case result do
          str when is_binary(str) -> Jason.decode!(str)
          list when is_list(list) -> list
        end

      assert parsed == []
    end
  end
end
