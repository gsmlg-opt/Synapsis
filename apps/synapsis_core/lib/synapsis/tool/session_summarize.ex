defmodule Synapsis.Tool.SessionSummarize do
  @moduledoc """
  Compress current session context into candidate semantic memory records.
  Returns candidates for review — does not persist.
  """
  use Synapsis.Tool

  import Ecto.Query

  @impl true
  def name, do: "session_summarize"

  @impl true
  def description,
    do:
      "Summarize current session into candidate memory records. Returns candidates for review — does not persist."

  @impl true
  def permission_level, do: :read

  @impl true
  def category, do: :memory

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "scope" => %{
          "type" => "string",
          "enum" => ["full", "recent", "range"],
          "description" => "What portion to summarize (default: full)"
        },
        "message_range" => %{
          "type" => "array",
          "items" => %{"type" => "integer"},
          "description" => "For 'range' scope: [start_index, end_index]"
        },
        "focus" => %{
          "type" => "string",
          "description" => "Hint to focus summarization (e.g. 'architectural decisions')"
        },
        "kinds" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Which memory kinds to extract"
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    session_id = context[:session_id]

    unless session_id do
      {:error, "No session_id in context"}
    else
      scope = Map.get(input, "scope", "full")
      focus = Map.get(input, "focus")
      kinds = Map.get(input, "kinds", ["fact", "decision", "lesson", "preference", "pattern"])

      # Load session messages
      messages = load_messages(session_id, scope, Map.get(input, "message_range"))

      if messages == [] do
        {:ok, Jason.encode!(%{candidates: [], message: "No messages to summarize"})}
      else
        # Extract candidates using heuristic summarization (no LLM call in Phase 1)
        candidates = extract_candidates(messages, focus, kinds)
        {:ok, Jason.encode!(%{candidates: candidates, message_count: length(messages)})}
      end
    end
  end

  defp load_messages(session_id, scope, range) do
    query =
      from(m in Synapsis.Message, where: m.session_id == ^session_id, order_by: m.inserted_at)

    query =
      case scope do
        "recent" ->
          query |> limit(10) |> order_by([m], desc: m.inserted_at)

        "range" when is_list(range) and length(range) == 2 ->
          [start, stop] = range
          query |> offset(^start) |> limit(^(stop - start))

        _ ->
          query
      end

    Synapsis.Repo.all(query)
  end

  defp extract_candidates(messages, focus, kinds) do
    # Heuristic extraction: analyze message content for key patterns
    # This is a simplified version; Phase 2 adds LLM-based summarization
    text =
      messages
      |> Enum.flat_map(fn msg ->
        case msg.parts do
          parts when is_list(parts) ->
            Enum.flat_map(parts, fn
              %Synapsis.Part.Text{content: c} when is_binary(c) -> [c]
              %{type: "text", content: c} when is_binary(c) -> [c]
              %{"type" => "text", "content" => c} when is_binary(c) -> [c]
              _ -> []
            end)

          _ ->
            []
        end
      end)
      |> Enum.join("\n")

    candidates = []

    # If there's a focus hint, create a focused candidate
    candidates =
      if focus && String.length(text) > 50 do
        candidate = %{
          kind: "fact",
          title: "Session summary: #{focus}",
          summary: String.slice(text, 0, 500),
          tags: [focus],
          importance: 0.7
        }

        [candidate | candidates]
      else
        candidates
      end

    # Generate basic candidates from message count/patterns
    candidates =
      if length(messages) >= 5 do
        topics =
          text
          |> String.downcase()
          |> String.split(~r/\W+/, trim: true)
          |> Enum.frequencies()
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(5)
          |> Enum.map(&elem(&1, 0))
          |> Enum.reject(&(String.length(&1) < 4))

        if topics != [] do
          candidate = %{
            kind: List.first(kinds) || "fact",
            title: "Session topics: #{Enum.join(Enum.take(topics, 3), ", ")}",
            summary:
              "Session covered #{length(messages)} messages. Key topics: #{Enum.join(topics, ", ")}.",
            tags: topics,
            importance: 0.5
          }

          [candidate | candidates]
        else
          candidates
        end
      else
        candidates
      end

    Enum.reverse(candidates)
  end
end
