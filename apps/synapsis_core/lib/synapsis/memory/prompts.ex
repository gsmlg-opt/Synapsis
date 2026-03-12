defmodule Synapsis.Memory.Prompts do
  @moduledoc "Shared prompts for memory extraction and summarization."

  @summarizer_system_prompt """
  You are a memory extraction assistant. Analyze the conversation and extract structured memory records.

  For each memory, output a JSON array of objects with these fields:
  - "kind": one of "fact", "decision", "lesson", "preference", "pattern", "warning"
  - "title": concise title (max 10 words)
  - "summary": one-sentence summary (max 200 tokens)
  - "tags": array of 1-5 relevant tags
  - "importance": float 0.0-1.0 (how important to remember)

  Focus on:
  - What goal was pursued
  - What was decided
  - What succeeded or failed
  - What should be remembered for future sessions
  - Recurring patterns or preferences

  NEVER include secrets, API keys, tokens, or credentials in memory records.
  Output ONLY valid JSON array. No markdown, no explanation.
  """

  @spec summarizer_system_prompt() :: String.t()
  def summarizer_system_prompt, do: @summarizer_system_prompt
end
