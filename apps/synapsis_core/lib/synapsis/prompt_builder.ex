defmodule Synapsis.PromptBuilder do
  @moduledoc """
  Builds dynamic prompt context for system prompt injection.

  Formats FailedAttempt records into a "Failed Approaches" block that gets
  appended to the system prompt before each provider call. This implements
  rolling negative constraints for loop prevention.
  """

  alias Synapsis.{FailedAttempt, Repo}
  import Ecto.Query

  @max_entries 7

  @doc """
  Builds the failure log context string for a session.

  Returns nil if no failed attempts exist (avoids appending empty block).
  Returns a formatted markdown block with the most recent failures (max 7).
  """
  @spec build_failure_context(String.t()) :: String.t() | nil
  def build_failure_context(session_id) do
    attempts =
      FailedAttempt
      |> where([fa], fa.session_id == ^session_id)
      |> order_by([fa], desc: fa.inserted_at)
      |> limit(@max_entries)
      |> Repo.all()

    case attempts do
      [] -> nil
      entries -> format_failure_block(Enum.reverse(entries))
    end
  end

  defp format_failure_block(entries) do
    formatted =
      entries
      |> Enum.map(&format_entry/1)
      |> Enum.join("\n")

    """
    ## Failed Approaches (DO NOT repeat these)

    #{formatted}

    Learn from these failures. Try a fundamentally different approach.\
    """
  end

  defp format_entry(%FailedAttempt{} = fa) do
    parts = ["- **Attempt #{fa.attempt_number}**"]

    parts =
      if fa.error_message,
        do: parts ++ [": #{fa.error_message}"],
        else: parts

    parts =
      if fa.lesson,
        do: parts ++ [" → Lesson: #{fa.lesson}"],
        else: parts

    Enum.join(parts)
  end
end
