defmodule Synapsis.PromptBuilder do
  @moduledoc """
  Builds dynamic prompt context for system prompt injection.

  Combines memory entries and failed attempts into context blocks that get
  appended to the system prompt before each provider call.
  """

  alias Synapsis.{FailedAttempt, MemoryEntry, Session, Repo}
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

  @doc """
  Builds the combined prompt context (memory + failures) for a session.

  Returns nil if neither memory entries nor failed attempts exist.
  """
  @spec build_prompt_context(String.t()) :: String.t() | nil
  def build_prompt_context(session_id) do
    parts =
      [build_memory_context(session_id), build_failure_context(session_id)]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  @doc """
  Builds memory context from global and project-scoped MemoryEntry records.

  Returns nil if no memory entries exist for the session's scope.
  """
  @spec build_memory_context(String.t()) :: String.t() | nil
  def build_memory_context(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        nil

      session ->
        global_entries =
          MemoryEntry
          |> where([m], m.scope == "global")
          |> where([m], is_nil(m.scope_id))
          |> order_by([m], asc: m.inserted_at)
          |> Repo.all()

        project_entries =
          MemoryEntry
          |> where([m], m.scope == "project" and m.scope_id == ^session.project_id)
          |> order_by([m], asc: m.inserted_at)
          |> Repo.all()

        entries = global_entries ++ project_entries

        case entries do
          [] -> nil
          entries -> format_memory_block(entries)
        end
    end
  end

  defp format_memory_block(entries) do
    formatted =
      entries
      |> Enum.map(fn entry -> "- **#{entry.key}**: #{entry.content}" end)
      |> Enum.join("\n")

    """
    ## Memory

    #{formatted}\
    """
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
