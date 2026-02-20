defmodule Synapsis.Session.AuditorTask do
  @moduledoc """
  Dual-model escalation: invokes an expensive reasoning model to analyze
  agent failures and produce lessons + new approach suggestions.

  Called by the Orchestrator when escalation is triggered (duplicate tool
  calls, test regressions). Runs as an async Task under the Tool
  TaskSupervisor. The result is persisted as a `FailedAttempt` record
  and injected into the system prompt via `PromptBuilder`.

  ## Configuration

  The auditor model/provider can be configured per-agent in `.opencode.json`:

  ```json
  {
    "agents": {
      "build": {
        "auditorProvider": "anthropic",
        "auditorModel": "claude-sonnet-4-20250514"
      }
    }
  }
  ```

  Falls back to the session's default provider if not configured.
  """

  require Logger

  alias Synapsis.{FailedAttempt, Repo, PromptBuilder}
  alias Synapsis.Session.Monitor

  @default_auditor_prompt """
  You are a code review auditor. An AI coding agent has been looping or
  making the same mistakes repeatedly. Analyze the failure context below
  and produce:

  1. A concise description of what went wrong (1-2 sentences)
  2. A specific lesson to avoid repeating this mistake
  3. A fundamentally different approach the agent should try next

  Be concrete and actionable. Do NOT repeat the failed approach.
  """

  @doc """
  Builds the auditor prompt from the current session context.

  This is a pure function that assembles the prompt — it does NOT
  call any LLM. The caller is responsible for sending this to a
  provider.

  Returns a map with `:system_prompt`, `:user_message`, and `:config`.
  """
  @spec build_auditor_request(String.t(), Monitor.t(), keyword()) :: map()
  def build_auditor_request(session_id, %Monitor{} = monitor, opts \\ []) do
    failure_context = PromptBuilder.build_failure_context(session_id)
    summary = Monitor.summary(monitor)

    user_message = build_user_message(summary, failure_context, opts)

    auditor_provider = Keyword.get(opts, :auditor_provider)
    auditor_model = Keyword.get(opts, :auditor_model)

    %{
      system_prompt: @default_auditor_prompt,
      user_message: user_message,
      config: %{
        provider: auditor_provider,
        model: auditor_model,
        max_tokens: 1024
      }
    }
  end

  @doc """
  Records the auditor's analysis as a FailedAttempt.

  Called after the auditor LLM responds. Parses the response and
  persists it for future system prompt injection.
  """
  @spec record_analysis(String.t(), String.t(), keyword()) ::
          {:ok, FailedAttempt.t()} | {:error, term()}
  def record_analysis(session_id, auditor_response, opts \\ []) do
    {error_message, lesson} = parse_auditor_response(auditor_response)
    attempt_number = next_attempt_number(session_id)

    attrs = %{
      session_id: session_id,
      attempt_number: attempt_number,
      error_message: error_message,
      lesson: lesson,
      triggered_by: Keyword.get(opts, :trigger, "orchestrator_escalation"),
      auditor_model: Keyword.get(opts, :auditor_model)
    }

    result =
      %FailedAttempt{}
      |> FailedAttempt.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, attempt} ->
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{session_id}",
          {"constraint_added",
           %{
             attempt_number: attempt.attempt_number,
             error_message: attempt.error_message,
             lesson: attempt.lesson
           }}
        )

        {:ok, attempt}

      error ->
        error
    end
  end

  @doc """
  Convenience: builds request, formats for logging/display.

  Does NOT invoke any LLM — returns the assembled prompt for
  the Worker or Orchestrator to send to the configured auditor provider.
  """
  @spec prepare_escalation(String.t(), Monitor.t(), map()) :: map()
  def prepare_escalation(session_id, monitor, agent_config) do
    opts = [
      auditor_provider: agent_config["auditorProvider"],
      auditor_model: agent_config["auditorModel"]
    ]

    request = build_auditor_request(session_id, monitor, opts)

    Logger.info("auditor_escalation_prepared",
      session_id: session_id,
      auditor_model: request.config.model
    )

    request
  end

  # -- Private --

  defp build_user_message(summary, failure_context, opts) do
    reason = Keyword.get(opts, :reason, "Unknown trigger")

    parts = [
      "## Escalation Trigger\n#{reason}\n",
      "## Monitor State\n" <>
        "- Iterations: #{summary.iteration_count}\n" <>
        "- Unique tool calls: #{summary.unique_tool_calls}\n" <>
        "- Max duplicate count: #{summary.max_duplicate_count}\n" <>
        "- Empty iterations: #{summary.consecutive_empty_iterations}\n" <>
        "- Test regressions: #{summary.test_regressions}\n"
    ]

    parts =
      if failure_context do
        parts ++ ["\n#{failure_context}"]
      else
        parts ++ ["\n(No previous failed attempts recorded)"]
      end

    Enum.join(parts, "\n")
  end

  defp parse_auditor_response(response) when is_binary(response) do
    # Extract structured parts from the auditor response
    # Heuristic: first paragraph = error, rest = lesson
    lines =
      response
      |> String.trim()
      |> String.split("\n", trim: true)

    case lines do
      [] ->
        {"No analysis provided", nil}

      [single] ->
        {single, nil}

      lines ->
        # First non-empty line(s) up to "lesson" or "approach" keyword = error
        # Rest = lesson
        {error_lines, lesson_lines} = split_at_lesson(lines)

        error = Enum.join(error_lines, " ") |> String.trim()
        lesson = Enum.join(lesson_lines, " ") |> String.trim()

        lesson = if lesson == "", do: nil, else: lesson
        {error, lesson}
    end
  end

  defp split_at_lesson(lines) do
    idx =
      Enum.find_index(lines, fn line ->
        lower = String.downcase(line)
        String.contains?(lower, "lesson") or String.contains?(lower, "approach")
      end)

    case idx do
      nil -> {lines, []}
      0 -> {[hd(lines)], tl(lines)}
      n -> Enum.split(lines, n)
    end
  end

  defp next_attempt_number(session_id) do
    import Ecto.Query

    current_max =
      FailedAttempt
      |> where([fa], fa.session_id == ^session_id)
      |> select([fa], max(fa.attempt_number))
      |> Repo.one()

    (current_max || 0) + 1
  end
end
