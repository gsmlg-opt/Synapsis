defmodule SynapsisWeb.MessageHelpers do
  @moduledoc """
  Pure functions for detecting and parsing message content patterns.

  Used by CoreComponents.message_parts/1 for dispatching to the
  appropriate rendering sub-component.
  """

  @compaction_regex ~r/\[Context Summary - (\d+) messages compacted\]\n(.*)\n\[End Summary\]/s

  @doc "Returns true if the content looks like a compaction summary."
  @spec compaction_summary?(any()) :: boolean()
  def compaction_summary?(content) when is_binary(content) do
    String.starts_with?(String.trim(content), "[Context Summary -")
  end

  def compaction_summary?(_), do: false

  @doc "Parses a compaction summary into {message_count, summary_text}."
  @spec parse_compaction(String.t()) :: {non_neg_integer(), String.t()}
  def parse_compaction(content) do
    case Regex.run(@compaction_regex, content) do
      [_, count_str, summary] -> {String.to_integer(count_str), String.trim(summary)}
      _ -> {0, content}
    end
  end

  @doc "Returns true if the content contains memory recall markers."
  @spec memory_recall?(any()) :: boolean()
  def memory_recall?(content) when is_binary(content) do
    String.contains?(content, "[Memory:") or
      String.contains?(content, "[Workspace Context]") or
      String.contains?(content, "[Recalled from")
  end

  def memory_recall?(_), do: false

  @doc "Detects the source of a memory recall marker."
  @spec detect_memory_source(String.t()) :: String.t()
  def detect_memory_source(content) do
    cond do
      String.contains?(content, "[Workspace Context]") ->
        "workspace"

      String.contains?(content, "[Recalled from") ->
        case Regex.run(~r/\[Recalled from (.+?)\]/, content) do
          [_, source] -> source
          _ -> "previous session"
        end

      true ->
        "memory"
    end
  end
end
