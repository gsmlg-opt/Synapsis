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
  7. Project Context (conditional)

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

    * `:project_id` — for project-scoped agents
    * `:session_id` — for memory relevance scoring
    * `:user_message` — latest user message for memory search
    * `:model_context_window` — model's context window size (default: 128_000)
    * `:agent_config` — agent configuration map

  """
  @spec build_system_prompt(atom(), keyword()) :: String.t()
  def build_system_prompt(agent_type, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    user_message = Keyword.get(opts, :user_message, "")
    model_context_window = Keyword.get(opts, :model_context_window, 128_000)
    agent_config = Keyword.get(opts, :agent_config, %{})

    layers = [
      {:base, load_base_prompt(agent_type, agent_config)},
      {:soul, load_soul(project_id)},
      {:identity, load_identity()},
      {:skills, build_skills_manifest(project_id)},
      {:memory, load_memory_context(user_message, project_id, model_context_window)},
      {:bootstrap, load_bootstrap()},
      {:project, load_project_context(project_id)}
    ]

    layers
    |> Enum.reject(fn {_key, val} -> is_nil(val) or val == "" end)
    |> Enum.map(fn {key, content} -> wrap_layer(key, content) end)
    |> Enum.join("\n\n")
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
  def load_soul(project_id) do
    Identity.load_soul(project_id)
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
  def build_skills_manifest(_project_id) do
    tools = Synapsis.Tool.Registry.list_for_llm()

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
    error ->
      Logger.warning("skills_manifest_failed", error: Exception.message(error))
      nil
  end

  @doc """
  Load relevant memory entries for the current turn.

  Uses the latest user message as the search query. Token budget is 5% of model
  context window, hard capped at 10 entries.
  """
  @spec load_memory_context(String.t(), String.t() | nil, pos_integer()) :: String.t() | nil
  def load_memory_context(query, project_id, model_context_window) do
    context = %{
      query: query || "",
      project_id: project_id || "",
      agent_scope: :project,
      memory_token_budget: memory_token_budget(model_context_window)
    }

    case MemoryContextBuilder.build(context) do
      "" -> nil
      content -> content
    end
  rescue
    error ->
      Logger.warning("memory_context_failed", error: Exception.message(error))
      nil
  end

  @doc "Load project-specific context from workspace."
  @spec load_project_context(String.t() | nil) :: String.t() | nil
  def load_project_context(nil), do: nil

  def load_project_context(project_id) do
    parts =
      [
        Identity.load_project_context(project_id)
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

  defp wrap_layer(:memory, content), do: "<memory>\n#{content}\n</memory>"
  defp wrap_layer(:bootstrap, content), do: "<environment>\n#{content}\n</environment>"
  defp wrap_layer(:project, content), do: "<project>\n#{content}\n</project>"

  defp truncate_description(desc, max_len) when byte_size(desc) <= max_len, do: desc

  defp truncate_description(desc, max_len) do
    String.slice(desc, 0, max_len - 1) <> "…"
  end

  defp default_base_prompt do
    """
    You are an AI coding assistant. Follow instructions precisely.
    Use tools when available. Be concise and direct.
    """
  end
end
