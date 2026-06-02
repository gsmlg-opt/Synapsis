defmodule Synapsis.Memory.SummarizerDispatcher do
  @moduledoc """
  Background session summarization — no longer an Oban worker.

  `enqueue/2` spawns a supervised Task via `Tool.TaskSupervisor`.
  The pipeline (load → compress → LLM → parse → store) is unchanged;
  persistence now goes through `Memory.Adapter` instead of Ecto directly.
  """

  require Logger

  alias Synapsis.{Message, Session}

  @event_threshold 10
  @summarizer_system_prompt Synapsis.Memory.Prompts.summarizer_system_prompt()

  @doc """
  Enqueue a summarization job for a session in a supervised background Task.
  Returns `{:ok, task}` or `:skip` when the event threshold is not met.
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Task.t()} | :skip | {:error, term()}
  def enqueue(session_id, opts \\ []) do
    args = %{
      session_id: session_id,
      focus: Keyword.get(opts, :focus),
      scope: Keyword.get(opts, :scope, "agent"),
      force: Keyword.get(opts, :force, false)
    }

    task =
      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
        run(args)
      end)

    {:ok, task}
  end

  @doc "Run a summarization job synchronously (used by tests and LocalScheduler)."
  @spec run(map()) :: :ok | {:skip, String.t()} | {:error, term()}
  def run(%{session_id: session_id} = args) do
    focus = args[:focus] || args["focus"]
    scope = args[:scope] || args["scope"] || "agent"
    force = args[:force] || args["force"] || false

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
        {:skip, reason}

      {:error, reason} = err ->
        Logger.warning("summarizer_failed", session_id: session_id, reason: inspect(reason))
        err
    end
  end

  # --- Private ---

  defp load_session(session_id) do
    case Synapsis.Session.Store.get_meta(session_id) do
      {:error, :not_found} -> {:error, "session not found"}
      {:ok, meta} -> {:ok, Session.from_meta(meta)}
    end
  end

  defp check_threshold(_session_id, true), do: :ok

  defp check_threshold(session_id, _force) do
    # ADR-006 C4: memory_events removed — gate on durable message count instead.
    count = length(Message.list_by_session(session_id))

    if count >= @event_threshold,
      do: :ok,
      else: {:skip, "only #{count} messages (threshold: #{@event_threshold})"}
  end

  defp load_messages(session_id), do: Message.list_by_session(session_id)

  defp compress_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      text =
        case msg.parts do
          parts when is_list(parts) ->
            parts
            |> Enum.flat_map(fn
              %Synapsis.Part.Text{content: c} when is_binary(c) -> [c]
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
    focus_instruction = if focus, do: "\n\nFocus especially on: #{focus}", else: ""
    messages = [%{role: "user", content: "#{compressed}#{focus_instruction}"}]
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
    agent_id = session.agent || "default"

    results =
      Enum.map(candidates, fn candidate ->
        importance = candidate["importance"] || 0.6

        if importance < 0.3 do
          :skipped
        else
          scope = candidate["scope"] || default_scope
          scope_id = if scope == "shared", do: "", else: agent_id

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
            source: "summarizer"
          }

          case Synapsis.Memory.Adapter.store(attrs) do
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

    Synapsis.Memory.append_event(%{
      type: "summary_created",
      agent_id: agent_id,
      scope: default_scope,
      scope_id: agent_id,
      correlation_id: session.id,
      payload: %{
        session_id: session.id,
        candidate_count: length(candidates),
        persisted_count: Enum.count(results, &(&1 == :ok))
      }
    })

    {:ok, Enum.count(results, &(&1 == :ok))}
  end
end
