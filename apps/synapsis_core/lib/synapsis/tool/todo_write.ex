defmodule Synapsis.Tool.TodoWrite do
  @moduledoc "Create or replace the session todo list."
  use Synapsis.Tool

  alias Synapsis.Session.Store

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
        # ADR-006 C4: the session todo list is a single session-scoped Concord
        # value (an ordered list), replaced atomically on each write.
        records =
          (input["todos"] || [])
          |> Enum.with_index()
          |> Enum.map(fn {todo, index} ->
            %{
              "todo_id" => todo["id"],
              "content" => todo["content"],
              "status" => safe_status(todo["status"]),
              "sort_order" => index
            }
          end)

        case Store.put_value(session_id, "todos", records) do
          :ok ->
            Phoenix.PubSub.broadcast(
              Synapsis.PubSub,
              "session:#{session_id}",
              {:todo_update, session_id, records}
            )

            {:ok, "Updated #{length(records)} todo(s)."}

          {:error, _reason} ->
            {:error, "Failed to update todos"}
        end
    end
  end

  defp safe_status(status) when status in ["pending", "in_progress", "completed"], do: status
  defp safe_status(_), do: "pending"

  defp get_in_struct(%{session_id: id}, :session_id), do: id
  defp get_in_struct(_, _), do: nil
end
