defmodule Synapsis.Tool.SessionSummarize do
  @moduledoc """
  Compress current session context into candidate semantic memory records.
  Returns candidates for review — does not persist.

  Uses LLM-based extraction when a provider is available, with heuristic
  fallback when LLM calls fail or are unavailable.
  """
  use Synapsis.Tool

  require Logger
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
        },
        "use_llm" => %{
          "type" => "boolean",
          "description" => "Use LLM for extraction (default: true, falls back to heuristic)"
        }
      }
    }
  end

  @summarizer_system_prompt Synapsis.Memory.Prompts.summarizer_system_prompt()

  @impl true
  def execute(input, context) do
    session_id = context[:session_id]

    unless session_id do
      {:error, "No session_id in context"}
    else
      scope = Map.get(input, "scope", "full")
      focus = Map.get(input, "focus")
      kinds = Map.get(input, "kinds", ["fact", "decision", "lesson", "preference", "pattern"])
      use_llm = Map.get(input, "use_llm", true)

      messages = load_messages(session_id, scope, Map.get(input, "message_range"))

      if messages == [] do
        {:ok, Jason.encode!(%{candidates: [], message: "No messages to summarize"})}
      else
        candidates =
          if use_llm do
            case extract_via_llm(messages, focus, context) do
              {:ok, llm_candidates} ->
                llm_candidates

              {:error, reason} ->
                Logger.info("session_summarize_llm_fallback",
                  session_id: session_id,
                  reason: inspect(reason)
                )

                extract_heuristic(messages, focus, kinds)
            end
          else
            extract_heuristic(messages, focus, kinds)
          end

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
          from(m in Synapsis.Message,
            where: m.session_id == ^session_id,
            order_by: [desc: m.inserted_at],
            limit: 10
          )

        "range" when is_list(range) and length(range) == 2 ->
          [start, stop] = range
          query |> offset(^start) |> limit(^(stop - start))

        _ ->
          query
      end

    Synapsis.Repo.all(query)
  end

  defp extract_text(messages) do
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
  end

  defp extract_via_llm(messages, focus, context) do
    compressed =
      messages
      |> Enum.map(fn msg ->
        text =
          case msg.parts do
            parts when is_list(parts) ->
              parts
              |> Enum.flat_map(fn
                %Synapsis.Part.Text{content: c} when is_binary(c) -> [c]
                %{type: "text", content: c} when is_binary(c) -> [c]
                %{"type" => "text", "content" => c} when is_binary(c) -> [c]
                _ -> []
              end)
              |> Enum.join(" ")

            _ ->
              ""
          end

        "#{msg.role}: #{String.slice(text, 0, 500)}"
      end)
      |> Enum.join("\n\n")
      |> String.slice(0, 8000)

    focus_instruction =
      if focus, do: "\n\nFocus especially on: #{focus}", else: ""

    llm_messages = [
      %{role: "user", content: "#{compressed}#{focus_instruction}"}
    ]

    # Resolve provider from session context
    session_id = context[:session_id]

    provider =
      case Synapsis.Repo.get(Synapsis.Session, session_id) do
        nil -> "anthropic"
        session -> session.provider || "anthropic"
      end

    case Synapsis.LLM.complete(llm_messages,
           provider: provider,
           system: @summarizer_system_prompt,
           max_tokens: 2048
         ) do
      {:ok, text} -> parse_llm_candidates(text)
      {:error, _} = err -> err
    end
  end

  defp parse_llm_candidates(text) do
    json_text =
      case Regex.run(~r/\[[\s\S]*\]/, text) do
        [match] -> match
        _ -> text
      end

    case Jason.decode(json_text) do
      {:ok, candidates} when is_list(candidates) ->
        valid =
          candidates
          |> Enum.filter(&is_map/1)
          |> Enum.filter(&(Map.has_key?(&1, "kind") and Map.has_key?(&1, "title")))
          |> Enum.map(fn c ->
            %{
              kind: c["kind"],
              title: c["title"],
              summary: c["summary"] || c["title"],
              tags: c["tags"] || [],
              importance: c["importance"] || 0.6
            }
          end)

        {:ok, valid}

      _ ->
        {:error, "failed to parse LLM response as JSON array"}
    end
  end

  defp extract_heuristic(messages, focus, kinds) do
    text = extract_text(messages)

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
