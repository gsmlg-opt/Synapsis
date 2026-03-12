defmodule Synapsis.Memory.SummarizerDispatcher do
  @moduledoc """
  Oban worker for background session summarization.

  Triggers:
  - `message_complete` broadcast (if enough new events since last summary)
  - Task/session completion
  - Explicit `session_summarize` tool invocation
  - Scheduled compaction window

  Pipeline:
  1. Load event range for session
  2. Compress: strip redundant tool outputs, collapse streaming chunks
  3. LLM call via `Synapsis.LLM.complete/2` (single-shot, no agent loop)
  4. Parse structured output into SemanticMemory candidates
  5. Apply promotion rules (importance threshold, kind filter)
  6. Insert into semantic_memories with appropriate scope
  7. Broadcast `:memory_promoted` via PubSub
  """

  use Oban.Worker,
    queue: :memory,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], keys: [:session_id]]

  require Logger
  import Ecto.Query

  alias Synapsis.Repo

  @event_threshold 10
  @summarizer_system_prompt Synapsis.Memory.Prompts.summarizer_system_prompt()

  @doc """
  Enqueues a summarization job for a session.

  Options:
  - `:focus` — optional hint to focus extraction
  - `:scope` — default scope for extracted memories (default: "project")
  - `:provider` — LLM provider to use (default: session's provider)
  - `:force` — bypass event threshold check
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(session_id, opts \\ []) do
    args =
      %{session_id: session_id}
      |> maybe_put(:focus, Keyword.get(opts, :focus))
      |> maybe_put(:scope, Keyword.get(opts, :scope))
      |> maybe_put(:provider, Keyword.get(opts, :provider))
      |> maybe_put(:force, Keyword.get(opts, :force))

    %{} |> Map.merge(args) |> __MODULE__.new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    session_id = args["session_id"]
    focus = args["focus"]
    scope = args["scope"] || "project"
    force = args["force"] || false

    Logger.info("summarizer_started", session_id: session_id, focus: focus)

    with {:ok, session} <- load_session(session_id),
         :ok <- check_threshold(session_id, force),
         messages when messages != [] <- load_messages(session_id),
         compressed <- compress_messages(messages),
         {:ok, candidates} <- extract_via_llm(compressed, focus, session),
         {:ok, count} <- persist_candidates(candidates, session, scope) do
      Logger.info("summarizer_completed",
        session_id: session_id,
        candidates_extracted: length(candidates),
        persisted: count
      )

      :ok
    else
      [] ->
        Logger.info("summarizer_skipped_no_messages", session_id: session_id)
        :ok

      {:skip, reason} ->
        Logger.info("summarizer_skipped", session_id: session_id, reason: reason)
        :ok

      {:error, reason} = err ->
        Logger.warning("summarizer_failed", session_id: session_id, reason: inspect(reason))
        err
    end
  end

  defp load_session(session_id) do
    case Repo.get(Synapsis.Session, session_id) do
      nil -> {:error, "session not found"}
      session -> {:ok, Repo.preload(session, :project)}
    end
  end

  defp check_threshold(_session_id, true), do: :ok

  defp check_threshold(session_id, _force) do
    # Use correlation_id to track events by session
    event_count =
      from(e in Synapsis.MemoryEvent,
        where: e.correlation_id == ^session_id,
        select: count()
      )
      |> Repo.one()

    last_summary =
      from(e in Synapsis.MemoryEvent,
        where: e.correlation_id == ^session_id and e.type == "summary_created",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()

    events_since =
      if last_summary do
        from(e in Synapsis.MemoryEvent,
          where: e.correlation_id == ^session_id and e.inserted_at > ^last_summary.inserted_at,
          select: count()
        )
        |> Repo.one()
      else
        event_count
      end

    if events_since >= @event_threshold do
      :ok
    else
      {:skip, "only #{events_since} events since last summary (threshold: #{@event_threshold})"}
    end
  end

  defp load_messages(session_id) do
    from(m in Synapsis.Message,
      where: m.session_id == ^session_id,
      order_by: m.inserted_at
    )
    |> Repo.all()
  end

  defp compress_messages(messages) do
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
  end

  defp extract_via_llm(compressed, focus, session) do
    focus_instruction =
      if focus, do: "\n\nFocus especially on: #{focus}", else: ""

    messages = [
      %{role: "user", content: "#{compressed}#{focus_instruction}"}
    ]

    provider = session.provider || "anthropic"

    case Synapsis.LLM.complete(messages,
           provider: provider,
           system: @summarizer_system_prompt,
           max_tokens: 2048
         ) do
      {:ok, text} -> parse_candidates(text)
      {:error, _} = err -> err
    end
  end

  defp parse_candidates(text) do
    # Extract JSON array from response (may have markdown wrapping)
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

        {:ok, valid}

      _ ->
        Logger.warning("summarizer_parse_failed", raw: String.slice(text, 0, 200))
        {:ok, []}
    end
  end

  defp persist_candidates(candidates, session, default_scope) do
    project_id = to_string(session.project_id)
    agent_id = session.agent || "default"

    results =
      Enum.map(candidates, fn candidate ->
        importance = candidate["importance"] || 0.6

        # Apply promotion rules: skip low-importance candidates
        if importance < 0.3 do
          :skipped
        else
          scope = candidate["scope"] || default_scope

          scope_id =
            case scope do
              "shared" -> ""
              "agent" -> agent_id
              _ -> project_id
            end

          attrs = %{
            scope: scope,
            scope_id: scope_id,
            kind: candidate["kind"] || "fact",
            title: candidate["title"],
            summary: candidate["summary"] || candidate["title"],
            tags: candidate["tags"] || [],
            importance: importance,
            confidence: 0.7,
            freshness: 1.0,
            source: "summarizer",
            contributed_by: agent_id
          }

          case Synapsis.Memory.store_semantic(attrs) do
            {:ok, mem} ->
              Synapsis.Memory.Cache.invalidate(scope, scope_id)

              Phoenix.PubSub.broadcast(
                Synapsis.PubSub,
                "memory:#{scope}:#{scope_id}",
                {:memory_promoted, mem.id}
              )

              :ok

            {:error, _} ->
              :error
          end
        end
      end)

    # Record summary_created event
    Synapsis.Memory.append_event(%{
      type: "summary_created",
      agent_id: agent_id,
      scope: default_scope,
      scope_id: project_id,
      correlation_id: session.id,
      payload: %{
        session_id: session.id,
        candidate_count: length(candidates),
        persisted_count: Enum.count(results, &(&1 == :ok))
      }
    })

    {:ok, Enum.count(results, &(&1 == :ok))}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
