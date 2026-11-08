defmodule Synapsis.TaskSuggestions.Acceptance do
  @moduledoc false
  @compile {:no_warn_undefined, Synapsis.Session.Worker}

  @instruction "Start by addressing this task in the current folder. If an isolated Git worktree is needed, explain why and ask the user before creating or switching to it."

  def run(suggestion, destination_id, requester_id, claim_id, deadline) do
    case Synapsis.Sessions.create_suggested_session(
           suggestion,
           destination_id,
           requester_id,
           deadline: deadline
         ) do
      {:ok, %{input_context: input_context}} ->
        launch(suggestion, destination_id, claim_id, input_context, deadline)

      {:error, {:pre_effect, _}} = rejection ->
        rejection

      _ ->
        {:error, :unknown_outcome}
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  defp launch(suggestion, destination_id, claim_id, input_context, deadline) do
    with {:ok, native} <-
           Synapsis.Session.Worker.start_suggested_turn(
             destination_id,
             %{
               task_id: suggestion.id,
               source_session_id: suggestion.session_id,
               claim_id: claim_id,
               content: @instruction <> "\n\n" <> suggestion.prompt,
               input_context: input_context
             },
             deadline: deadline
           ),
         true <- valid_receipt?(native, destination_id, input_context) do
      {:ok,
       Map.take(native, [:run_id, :turn_id, :message_id, :input_id])
       |> Map.merge(%{
         task_id: suggestion.id,
         session_id: destination_id,
         source_session_id: suggestion.session_id,
         status: "accepted"
       })}
    else
      _ -> {:error, :unknown_outcome}
    end
  end

  defp valid_receipt?(native, destination_id, input_context) when is_map(native) do
    native[:status] == :started and native[:session_id] == destination_id and
      native[:input_id] == input_context["input_id"] and
      Enum.all?([:run_id, :turn_id, :message_id, :input_id], fn key ->
        is_binary(native[key]) and native[key] != ""
      end)
  end

  defp valid_receipt?(_, _, _), do: false
end
