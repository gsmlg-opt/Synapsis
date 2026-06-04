defmodule Synapsis.Tool.ExitPlanMode do
  @moduledoc "Exit plan mode and return to build mode with full tool access."
  use Synapsis.Tool

  @impl true
  def name, do: "exit_plan_mode"

  @impl true
  def description,
    do: "Exit plan mode and return to build mode with full tool access."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :session

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "plan" => %{
          "type" => "string",
          "description" => "The plan to submit for approval"
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    session_id = context[:session_id] || get_in_struct(context, :session_id)

    case session_id do
      nil ->
        {:error, "No session context"}

      session_id ->
        plan = input["plan"]

        case Synapsis.Session.Store.get_meta(session_id) do
          {:error, :not_found} ->
            {:error, "Session not found: #{session_id}"}

          {:ok, meta} ->
            Synapsis.Session.Store.put_meta(session_id, Map.put(meta, :agent, "main"))

            Phoenix.PubSub.broadcast(
              Synapsis.PubSub,
              "session:#{session_id}",
              {:plan_submitted, plan}
            )

            Phoenix.PubSub.broadcast(
              Synapsis.PubSub,
              "session:#{session_id}",
              {:agent_mode_changed, :main}
            )

            {:ok, "Exited plan mode"}
        end
    end
  end

  defp get_in_struct(%{session_id: id}, :session_id), do: id
  defp get_in_struct(_, _), do: nil
end
