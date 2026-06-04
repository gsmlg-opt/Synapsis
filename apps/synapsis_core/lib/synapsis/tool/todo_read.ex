defmodule Synapsis.Tool.TodoRead do
  @moduledoc "Read the current session todo list."
  use Synapsis.Tool

  alias Synapsis.Session.Store

  @impl true
  def name, do: "todo_read"

  @impl true
  def description, do: "Read the current session todo list."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :planning

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{}
    }
  end

  @impl true
  def execute(_input, context) do
    session_id = context[:session_id] || get_in_struct(context, :session_id)

    case session_id do
      nil ->
        {:ok, []}

      session_id ->
        todos =
          session_id
          |> Store.get_value("todos", [])
          |> Enum.sort_by(&(&1["sort_order"] || 0))
          |> Enum.map(fn todo ->
            %{
              id: todo["todo_id"],
              content: todo["content"],
              status: to_string(todo["status"] || "pending"),
              sort_order: todo["sort_order"] || 0
            }
          end)

        {:ok, todos}
    end
  end

  defp get_in_struct(%{session_id: id}, :session_id), do: id
  defp get_in_struct(_, _), do: nil
end
