defmodule Synapsis.Tool.TodoWrite do
  @moduledoc "Create or replace the session todo list."
  use Synapsis.Tool

  import Ecto.Query

  @impl true
  def name, do: "todo_write"

  @impl true
  def description, do: "Create or replace the session todo list."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :planning

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "todos" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "content" => %{"type" => "string"},
              "status" => %{
                "type" => "string",
                "enum" => ["pending", "in_progress", "completed"]
              }
            },
            "required" => ["id", "content", "status"]
          }
        }
      },
      "required" => ["todos"]
    }
  end

  @impl true
  def execute(input, context) do
    session_id = context[:session_id] || get_in_struct(context, :session_id)

    case session_id do
      nil ->
        {:error, "session_id is required in context"}

      session_id ->
        todos = input["todos"] || []

        Synapsis.Repo.transaction(fn ->
          # Delete all existing todos for this session
          from(t in Synapsis.SessionTodo, where: t.session_id == ^session_id)
          |> Synapsis.Repo.delete_all()

          # Insert new todos with sort_order from array index
          inserted =
            todos
            |> Enum.with_index()
            |> Enum.map(fn {todo, index} ->
              attrs = %{
                session_id: session_id,
                todo_id: todo["id"],
                content: todo["content"],
                status: safe_status_atom(todo["status"]),
                sort_order: index
              }

              case %Synapsis.SessionTodo{}
                   |> Synapsis.SessionTodo.changeset(attrs)
                   |> Synapsis.Repo.insert() do
                {:ok, todo} -> todo
                {:error, changeset} -> Synapsis.Repo.rollback(changeset)
              end
            end)

          inserted
        end)
        |> case do
          {:ok, inserted} ->
            Phoenix.PubSub.broadcast(
              Synapsis.PubSub,
              "session:#{session_id}",
              {:todo_update, session_id, inserted}
            )

            {:ok, "Updated #{length(inserted)} todo(s)."}

          {:error, _reason} ->
            {:error, "Failed to update todos"}
        end
    end
  end

  defp safe_status_atom(status) when status in ["pending", "in_progress", "completed"],
    do: String.to_existing_atom(status)

  defp safe_status_atom(nil), do: :pending
  defp safe_status_atom(_), do: :pending

  defp get_in_struct(%{session_id: id}, :session_id), do: id
  defp get_in_struct(_, _), do: nil
end
