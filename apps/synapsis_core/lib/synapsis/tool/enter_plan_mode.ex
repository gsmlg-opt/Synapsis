defmodule Synapsis.Tool.EnterPlanMode do
  @moduledoc "Switch the session to plan mode, restricting tool access to read-only tools."
  use Synapsis.Tool

  @impl true
  def name, do: "enter_plan_mode"

  @impl true
  def description,
    do: "Switch the session to plan mode, restricting tool access to read-only tools."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :session

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
        {:error, "No session context"}

      session_id ->
        session = Synapsis.Repo.get!(Synapsis.Session, session_id)

        session
        |> Synapsis.Session.changeset(%{agent: "plan"})
        |> Synapsis.Repo.update!()

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{session_id}",
          {:agent_mode_changed, :plan}
        )

        {:ok, "Entered plan mode"}
    end
  end

  defp get_in_struct(%{session_id: id}, :session_id), do: id
  defp get_in_struct(_, _), do: nil
end
