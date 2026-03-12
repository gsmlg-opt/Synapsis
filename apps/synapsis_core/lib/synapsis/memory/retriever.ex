defmodule Synapsis.Memory.Retriever do
  @moduledoc """
  Retrieves and ranks semantic memories by relevance.

  Retrieval stages:
  1. Hard filtering (scope visibility, archive status, kind)
  2. Candidate generation (keyword search on title + summary, tag matching)
  3. Reranking (weighted score: keyword_match, importance, recency, confidence, freshness)
  4. Packing (select top memories within token budget)
  """

  alias Synapsis.Memory.Cache

  @default_limit 5
  @weights %{
    keyword_match: 0.30,
    importance: 0.25,
    recency: 0.15,
    confidence: 0.15,
    freshness: 0.10,
    success_bias: 0.05
  }

  @type retrieve_opts :: %{
          query: String.t(),
          scope: atom(),
          agent_id: String.t() | nil,
          project_id: String.t() | nil,
          kinds: [String.t()] | nil,
          tags: [String.t()] | nil,
          limit: non_neg_integer()
        }

  @doc "Retrieve ranked memories based on query and scope context."
  @spec retrieve(retrieve_opts()) :: [map()]
  def retrieve(opts) do
    query = Map.get(opts, :query, "")
    limit = Map.get(opts, :limit, @default_limit)

    cache_key = build_cache_key(opts)

    case Cache.get(cache_key) do
      {:ok, cached} ->
        cached

      :miss ->
        results = do_retrieve(query, opts, limit)
        Cache.put(cache_key, results)

        # Touch access stats in background
        ids = Enum.map(results, & &1.id)

        if ids != [] do
          Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
            try do
              Synapsis.Memory.touch_accessed(ids)
            rescue
              _ -> :ok
            end
          end)
        end

        results
    end
  end

  defp do_retrieve(query, opts, limit) do
    scope_pairs = build_scope_pairs(opts)
    filters = build_filters(opts, scope_pairs)

    candidates =
      if query != "" and String.length(query) >= 2 do
        Synapsis.Memory.search_semantic(query, filters ++ [limit: limit * 3])
      else
        Synapsis.Memory.list_semantic(filters ++ [active: true, limit: limit * 3])
      end

    now = DateTime.utc_now()

    candidates
    |> Enum.map(&score_candidate(&1, query, now))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp build_scope_pairs(opts) do
    agent_scope = Map.get(opts, :scope, :project)
    agent_id = Map.get(opts, :agent_id)
    project_id = Map.get(opts, :project_id, "")

    case agent_scope do
      :agent when is_binary(agent_id) ->
        [
          {"agent", agent_id},
          {"project", project_id},
          {"shared", ""}
        ]

      :project ->
        [
          {"project", project_id},
          {"shared", ""}
        ]

      :shared ->
        [{"shared", ""}]

      _ ->
        [{"shared", ""}]
    end
  end

  defp build_filters(opts, scope_pairs) do
    filters = [scopes: scope_pairs, active: true]

    filters =
      case Map.get(opts, :kinds) do
        nil -> filters
        kinds when is_list(kinds) -> [{:kinds, kinds} | filters]
      end

    case Map.get(opts, :tags) do
      nil -> filters
      tags when is_list(tags) -> [{:tags, tags} | filters]
    end
  end

  defp score_candidate(memory, query, now) do
    keyword_score = keyword_match_score(memory, query)
    importance_score = memory.importance || 0.5
    recency_score = recency_score(memory.inserted_at, now)
    confidence_score = memory.confidence || 0.5
    freshness_score = memory.freshness || 1.0
    success_score = if memory.kind in ["lesson", "pattern", "decision"], do: 0.8, else: 0.5

    score =
      keyword_score * @weights.keyword_match +
        importance_score * @weights.importance +
        recency_score * @weights.recency +
        confidence_score * @weights.confidence +
        freshness_score * @weights.freshness +
        success_score * @weights.success_bias

    %{
      id: memory.id,
      scope: memory.scope,
      scope_id: memory.scope_id,
      kind: memory.kind,
      title: memory.title,
      summary: memory.summary,
      tags: memory.tags,
      contributed_by: memory.contributed_by,
      importance: memory.importance,
      confidence: memory.confidence,
      score: Float.round(score, 4)
    }
  end

  defp keyword_match_score(_memory, ""), do: 0.0
  defp keyword_match_score(_memory, nil), do: 0.0

  defp keyword_match_score(memory, query) do
    query_terms =
      query
      |> String.downcase()
      |> String.split(~r/\W+/, trim: true)
      |> MapSet.new()

    text =
      String.downcase("#{memory.title} #{memory.summary} #{Enum.join(memory.tags || [], " ")}")

    text_terms =
      text
      |> String.split(~r/\W+/, trim: true)
      |> MapSet.new()

    matches = MapSet.intersection(query_terms, text_terms) |> MapSet.size()
    total = MapSet.size(query_terms)

    if total > 0, do: matches / total, else: 0.0
  end

  defp recency_score(nil, _now), do: 0.0

  defp recency_score(inserted_at, now) do
    age_hours = DateTime.diff(now, inserted_at, :hour)

    cond do
      age_hours < 1 -> 1.0
      age_hours < 24 -> 0.9
      age_hours < 168 -> 0.7
      age_hours < 720 -> 0.5
      age_hours < 2160 -> 0.3
      true -> 0.1
    end
  end

  defp build_cache_key(opts) do
    {
      Map.get(opts, :query, ""),
      Map.get(opts, :scope),
      Map.get(opts, :agent_id),
      Map.get(opts, :project_id),
      Map.get(opts, :kinds),
      Map.get(opts, :tags),
      Map.get(opts, :limit, @default_limit)
    }
  end
end
