defmodule Synapsis.Agent.ContextBuilder do
  @moduledoc """
  Builds the full system prompt for LLM requests (AI-2).

  Assembles context in layers:
  1. Base Prompt (hardcoded per agent type)
  2. Soul (workspace file)
  3. Identity (workspace file)
  4. Skills Manifest (computed from tool registry)
  5. Memory Context (auto-retrieved)
  6. Bootstrap (workspace file)
  7. Agent Context (conditional)

  Each layer is wrapped in XML tags for unambiguous LLM parsing.
  """

  require Logger

  alias Synapsis.Workspace.Identity
  alias Synapsis.Memory.ContextBuilder, as: MemoryContextBuilder

  @memory_budget_ratio 0.05
  @memory_hard_cap 10

  @doc """
  Build the full system prompt for an agent turn.

  ## Options

    * `:agent_id` — for agent-scoped workspace context
    * `:session_id` — for memory relevance scoring
    * `:user_message` — latest user message for memory search
    * `:model_context_window` — model's context window size (default: 128_000)
    * `:agent_config` — agent configuration map

  """
  @spec build_system_prompt(atom(), keyword()) :: String.t()
  def build_system_prompt(agent_type, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    user_message = Keyword.get(opts, :user_message, "")
    model_context_window = Keyword.get(opts, :model_context_window, 128_000)
    agent_config = Keyword.get(opts, :agent_config, %{})

    layers = [
      {:base, load_base_prompt(agent_type, agent_config)},
      {:soul, load_soul(agent_id)},
      {:identity, load_identity()},
      {:assigned_skills, build_assigned_skills(agent_config)},
      {:skills, build_skills_manifest(agent_id, agent_config)},
      {:memory, load_memory_context(user_message, agent_id, model_context_window)},
      {:bootstrap, load_bootstrap()},
      {:agent, load_agent_context(agent_id)}
    ]

    layers
    |> Enum.reject(fn {_key, val} -> is_nil(val) or val == "" end)
    |> Enum.map(fn {key, content} -> wrap_layer(key, content) end)
    |> Enum.join("\n\n")
  end

  @doc """
  Assemble the context injection payload for spawning a Code Agent.

  Returns a map with the task description and system context so the spawned
  Code Agent can pick up work without re-loading identity files.

  ## Options

    * `:agent_id` — agent the child will work as
    * `:session_id` — parent session ID for correlation
    * `:task` — natural-language task description
    * `:agent_config` — agent configuration to pass to the child

  """
  @spec build_coding_context(keyword()) :: map()
  def build_coding_context(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    task = Keyword.get(opts, :task, "")
    agent_config = Keyword.get(opts, :agent_config, %{})

    %{
      task: task,
      agent_id: agent_id,
      agent_config: agent_config,
      soul: load_soul(agent_id),
      agent_context: load_agent_context(agent_id)
    }
  end

  @doc "Load the base prompt for an agent type."
  @spec load_base_prompt(atom(), map()) :: String.t()
  def load_base_prompt(_agent_type, agent_config) do
    Map.get(agent_config, :system_prompt) ||
      Map.get(agent_config, "system_prompt") ||
      default_base_prompt()
  end

  @doc "Load soul from workspace identity files."
  @spec load_soul(String.t() | nil) :: String.t() | nil
  def load_soul(agent_id) do
    Identity.load_soul(agent_id)
  end

  @doc "Load user identity from workspace."
  @spec load_identity() :: String.t() | nil
  def load_identity do
    Identity.load_identity()
  end

  @doc "Load bootstrap/environment from workspace."
  @spec load_bootstrap() :: String.t() | nil
  def load_bootstrap do
    Identity.load_bootstrap()
  end

  @doc """
  Build a compact skills manifest listing available tools.

  Queries the tool registry for enabled tools and formats them as a one-line-per-tool list.
  MCP/LSP tools get a provider prefix.
  """
  @spec build_skills_manifest(String.t() | nil) :: String.t() | nil
  @spec build_skills_manifest(String.t() | nil, map()) :: String.t() | nil
  def build_skills_manifest(agent_id, agent_config \\ %{})

  def build_skills_manifest(_agent_id, agent_config) do
    tool_names = assigned_tool_names(agent_config)

    tools =
      Synapsis.Tool.Registry.list_for_llm()
      |> maybe_filter_tools(tool_names)

    case tools do
      [] ->
        nil

      tools ->
        lines =
          tools
          |> Enum.map(fn tool ->
            name = tool.name
            desc = truncate_description(tool.description || "", 80)
            "- #{name}: #{desc}"
          end)
          |> Enum.join("\n")

        "Available skills:\n#{lines}"
    end
  rescue
    e in [RuntimeError, Ecto.QueryError] ->
      Logger.warning("skills_manifest_failed", error: Exception.message(e))
      nil
  end

  @doc """
  Load relevant memory entries for the current turn.

  Uses the latest user message as the search query. Token budget is 5% of model
  context window, hard capped at 10 entries.
  """
  @memory_context_timeout 4_000

  @spec load_memory_context(String.t(), String.t() | nil, pos_integer()) :: String.t() | nil
  def load_memory_context(query, agent_id, model_context_window) do
    context = %{
      query: query || "",
      agent_id: agent_id || "",
      agent_scope: :agent,
      memory_token_budget: memory_token_budget(model_context_window)
    }

    # Memory retrieval must never block the prompt-building path indefinitely.
    task = Task.async(fn -> MemoryContextBuilder.build(context) end)

    case Task.yield(task, @memory_context_timeout) || Task.shutdown(task) do
      {:ok, ""} ->
        nil

      {:ok, content} ->
        content

      nil ->
        Logger.warning("memory_context_timeout", agent_id: agent_id)
        nil
    end
  rescue
    e in [RuntimeError, Ecto.QueryError] ->
      Logger.warning("memory_context_failed", error: Exception.message(e))
      nil
  end

  @doc "Load agent-specific context from workspace."
  @spec load_agent_context(String.t() | nil) :: String.t() | nil
  def load_agent_context(nil), do: nil

  def load_agent_context(agent_id) do
    parts =
      [
        Identity.load_agent_context(agent_id)
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  @doc """
  Calculate memory token budget based on model context window.

  Returns 5% of context window. Used to limit memory injection size.
  """
  @spec memory_token_budget(pos_integer()) :: pos_integer()
  def memory_token_budget(model_context_window) do
    trunc(model_context_window * @memory_budget_ratio)
  end

  @doc """
  Calculate memory entry limits based on model context window.

  Returns `%{max_tokens: integer, max_entries: integer}`.
  """
  @spec memory_budget(pos_integer()) :: %{max_tokens: pos_integer(), max_entries: pos_integer()}
  def memory_budget(model_context_window) do
    max_tokens = trunc(model_context_window * @memory_budget_ratio)

    %{
      max_tokens: max_tokens,
      max_entries: min(@memory_hard_cap, max(3, div(max_tokens, 500)))
    }
  end

  # -- Private --

  defp wrap_layer(:base, content), do: content
  defp wrap_layer(:soul, content), do: "<soul>\n#{content}\n</soul>"
  defp wrap_layer(:identity, content), do: "<user_identity>\n#{content}\n</user_identity>"

  defp wrap_layer(:skills, content),
    do: "<available_skills>\n#{content}\n</available_skills>"

  defp wrap_layer(:assigned_skills, content),
    do: "<assigned_skills>\n#{content}\n</assigned_skills>"

  defp wrap_layer(:memory, content), do: "<memory>\n#{content}\n</memory>"
  defp wrap_layer(:bootstrap, content), do: "<environment>\n#{content}\n</environment>"
  defp wrap_layer(:agent, content), do: "<agent_context>\n#{content}\n</agent_context>"

  defp truncate_description(desc, max_len) do
    if String.length(desc) <= max_len do
      desc
    else
      String.slice(desc, 0, max_len - 1) <> "…"
    end
  end

  defp maybe_filter_tools(tools, []), do: tools
  defp maybe_filter_tools(tools, nil), do: tools
  defp maybe_filter_tools(_tools, :none), do: []
  defp maybe_filter_tools(tools, :all), do: tools

  defp maybe_filter_tools(tools, tool_names) when is_list(tool_names) do
    names = MapSet.new(tool_names)
    Enum.filter(tools, &(MapSet.member?(names, &1.name) || MapSet.member?(names, &1[:name])))
  end

  defp assigned_tool_names(agent_config) when is_map(agent_config) do
    cond do
      Map.has_key?(agent_config, :tools) -> explicit_tool_names(Map.get(agent_config, :tools))
      Map.has_key?(agent_config, "tools") -> explicit_tool_names(Map.get(agent_config, "tools"))
      true -> :all
    end
  end

  defp assigned_tool_names(_agent_config), do: :all
  defp explicit_tool_names([]), do: :none
  defp explicit_tool_names(nil), do: :none
  defp explicit_tool_names(tool_names), do: tool_names

  defp build_assigned_skills(agent_config) do
    skills = Map.get(agent_config, :skills) || Map.get(agent_config, "skills") || []

    skills
    |> Enum.map(&format_assigned_skill/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n\n")
    end
  end

  defp format_assigned_skill(skill) do
    fragment = skill_value(skill, :system_prompt_fragment)

    if is_binary(fragment) and String.trim(fragment) != "" do
      name = skill_value(skill, :name) || "unnamed-skill"
      description = skill_value(skill, :description)

      ["## #{name}", description, fragment]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(is_binary(&1) and String.trim(&1) == ""))
      |> Enum.join("\n")
    else
      ""
    end
  end

  defp skill_value(skill, key) when is_map(skill) do
    Map.get(skill, key) || Map.get(skill, to_string(key))
  end

  defp skill_value(_skill, _key), do: nil

  defp default_base_prompt do
    """
    You are an AI coding assistant. Follow instructions precisely.
    Use tools when available. Be concise and direct.
    """
  end
end
