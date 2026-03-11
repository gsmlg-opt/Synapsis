defmodule Synapsis.Memory.ContextBuilder do
  @moduledoc """
  Builds memory context for injection into LLM requests as a dynamic system message.
  Formats retrieved memories into structured XML sections with token budget allocation.

  Budget allocation:
  - Shared: ~5%
  - Project: ~50%
  - Agent: ~20%
  - Session (working memory): ~25%
  """

  alias Synapsis.Memory.Retriever

  @default_max_tokens 1000
  @budget %{
    shared: 0.05,
    project: 0.50,
    agent: 0.20,
    session: 0.25
  }

  @doc """
  Build memory context string for prompt injection.

  Returns empty string if no relevant memories found.
  """
  @spec build(map()) :: String.t()
  def build(context) do
    query = extract_query_signal(context)
    project_id = Map.get(context, :project_id, "")
    agent_id = Map.get(context, :agent_id)
    agent_scope = Map.get(context, :agent_scope, :project)
    max_tokens = Map.get(context, :memory_token_budget, @default_max_tokens)

    # Retrieve memories at different scope levels
    shared_memories = retrieve_scope(:shared, query, nil, "", max_tokens)
    project_memories = retrieve_scope(:project, query, nil, project_id, max_tokens)

    agent_memories =
      if agent_scope == :agent and agent_id do
        retrieve_scope(:agent, query, agent_id, project_id, max_tokens)
      else
        []
      end

    # Format into XML sections
    sections = []

    sections =
      if shared_memories != [] do
        budget = trunc(max_tokens * @budget.shared)
        entries = format_entries(shared_memories, budget)
        sections ++ ["<shared>\n#{entries}\n</shared>"]
      else
        sections
      end

    sections =
      if project_memories != [] do
        budget = trunc(max_tokens * @budget.project)
        entries = format_entries(project_memories, budget)
        sections ++ ["<project context=\"#{project_id}\">\n#{entries}\n</project>"]
      else
        sections
      end

    sections =
      if agent_memories != [] do
        budget = trunc(max_tokens * @budget.agent)
        entries = format_entries(agent_memories, budget)
        sections ++ ["<agent context=\"#{agent_id}\">\n#{entries}\n</agent>"]
      else
        sections
      end

    if sections == [] do
      ""
    else
      "<memory>\n#{Enum.join(sections, "\n\n")}\n</memory>"
    end
  end

  defp retrieve_scope(scope, query, agent_id, project_id, _max_tokens) do
    Retriever.retrieve(%{
      query: query,
      scope: scope,
      agent_id: agent_id,
      project_id: project_id,
      limit: scope_limit(scope)
    })
  end

  defp scope_limit(:shared), do: 3
  defp scope_limit(:project), do: 5
  defp scope_limit(:agent), do: 3

  defp extract_query_signal(context) do
    # Extract query from latest user message or current goal
    cond do
      is_binary(Map.get(context, :query)) ->
        context.query

      is_binary(Map.get(context, :current_goal)) ->
        context.current_goal

      is_list(Map.get(context, :messages)) ->
        context.messages
        |> Enum.reverse()
        |> Enum.find_value("", fn
          %{role: "user", content: content} when is_binary(content) -> content
          %{role: :user, content: content} when is_binary(content) -> content
          _ -> nil
        end)

      true ->
        ""
    end
  end

  defp format_entries(memories, budget_tokens) do
    # Approximate: 1 token ≈ 4 chars
    budget_chars = budget_tokens * 4

    memories
    |> Enum.reduce_while({[], 0}, fn mem, {acc, used} ->
      line = "- #{mem.summary}"
      line_chars = String.length(line)

      if used + line_chars <= budget_chars do
        {:cont, {[line | acc], used + line_chars}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
