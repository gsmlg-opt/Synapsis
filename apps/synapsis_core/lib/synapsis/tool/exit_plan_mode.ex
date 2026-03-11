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

        case Synapsis.Repo.get(Synapsis.Session, session_id) do
          nil ->
            {:error, "Session not found: #{session_id}"}

          session ->
            case session
                 |> Synapsis.Session.changeset(%{agent: "build"})
                 |> Synapsis.Repo.update() do
              {:ok, _updated} ->
                Phoenix.PubSub.broadcast(
                  Synapsis.PubSub,
                  "session:#{session_id}",
                  {:plan_submitted, plan}
                )

                Phoenix.PubSub.broadcast(
                  Synapsis.PubSub,
                  "session:#{session_id}",
                  {:agent_mode_changed, :build}
                )

                {:ok, "Exited plan mode"}

              {:error, changeset} ->
                {:error, "Failed to exit plan mode: #{inspect(changeset.errors)}"}
            end
        end
    end
  end

  defp get_in_struct(%{session_id: id}, :session_id), do: id
  defp get_in_struct(_, _), do: nil
end
