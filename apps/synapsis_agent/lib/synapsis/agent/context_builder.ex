defmodule Synapsis.Agent.ContextBuilder do
  @moduledoc """
  Builds the full system prompt for LLM requests (AI-2).

  Assembles context in layers:
  1. Base Prompt (hardcoded per agent type)
  2. Soul (workspace file)
  3. Identity (workspace file)
  4. Skills Manifest (selected tool descriptions)
  5. Memory Context (auto-retrieved)
  6. Bootstrap (workspace file)
  7. Agent Context (conditional)

  Each layer is wrapped in XML tags for unambiguous LLM parsing.
  """

  require Logger

  alias Synapsis.{SkillCatalog, Workspace.Identity}
  alias Synapsis.Agent.Tools.DisplayCatalog
  alias Synapsis.Memory.ContextBuilder, as: MemoryContextBuilder
  alias Synapsis.Provider.ModelRegistry

  @memory_budget_ratio 0.05
  @memory_hard_cap 10

  @doc """
  Build the full system prompt for an agent turn.

  ## Options

    * `:agent_id` — for agent-scoped workspace context
    * `:session_id` — for memory relevance scoring
    * `:user_message` — latest user message for memory search
    * `:model_context_window` — explicit model context window size
    * `:agent_config` — agent configuration map
    * `:workspace_path` — trusted workspace for Markdown memory
    * `:memory_context` — false for child or shared conversations

  """
  @spec build_system_prompt(atom(), keyword()) :: String.t()
  def build_system_prompt(agent_type, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    user_message = Keyword.get(opts, :user_message, "")
    agent_config = Keyword.get(opts, :agent_config, %{})
    skill_context_window = skill_context_window(opts, agent_config)
    memory_context_window = skill_context_window || 128_000

    layers = [
      {:base, load_base_prompt(agent_type, agent_config)},
      {:soul, load_soul(agent_id)},
      {:identity, load_identity()},
      {:skill_catalog, build_skill_catalog(agent_config, skill_context_window)},
      {:remote_skills, build_remote_skills(agent_config, skill_context_window)},
      {:skills, build_skills_manifest(agent_id, agent_config)},
      {:memory,
       if(Keyword.get(opts, :memory_context, true),
         do:
           load_memory_context(
             user_message,
             agent_id,
             memory_context_window,
             Keyword.get(opts, :workspace_path)
           )
       )},
      {:shared_memory, load_shared_memory_instructions(agent_config, opts)},
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
  Build a compact manifest describing the selected tools.

  Explicit resolved definitions are authoritative. Otherwise, native contract v1
  selections use static display metadata and already captured MCP source snapshots.
  This descriptive projection does not establish runtime admission or readiness.
  """
  @spec build_skills_manifest(String.t() | nil) :: String.t() | nil
  @spec build_skills_manifest(String.t() | nil, map()) :: String.t() | nil
  def build_skills_manifest(agent_id, agent_config \\ %{})

  def build_skills_manifest(_agent_id, agent_config) do
    tools =
      case Map.get(agent_config, :resolved_tools) do
        tools when is_list(tools) -> tools
        _other -> selected_tool_metadata(agent_config)
      end

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

        "Selected tools:\n#{lines}"
    end
  rescue
    e in [RuntimeError, Ecto.QueryError] ->
      Logger.warning("skills_manifest_failed", error: Exception.message(e))
      nil
  end

  @doc """
  Load bounded workspace Markdown for the current root turn.
  Earlier notes are retrieved on demand by memory_search.
  """
  @memory_context_timeout 4_000

  @spec load_memory_context(String.t(), String.t() | nil, pos_integer()) :: String.t() | nil
  def load_memory_context(query, agent_id, model_context_window, workspace_path \\ nil) do
    context = %{
      query: query || "",
      agent_id: agent_id || "",
      agent_scope: :agent,
      workspace_path: workspace_path,
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

  @doc "Resolve the context window used for Skill catalog budgeting."
  @spec skill_context_window(keyword(), map()) :: pos_integer() | nil
  def skill_context_window(opts, agent_config) do
    cond do
      Keyword.has_key?(opts, :model_context_window) ->
        positive_integer_or_nil(Keyword.get(opts, :model_context_window))

      window = positive_integer_or_nil(agent_config[:model_context_window]) ->
        window

      provider = Map.get(agent_config, :provider) || Map.get(agent_config, "provider") ->
        model = Map.get(agent_config, :model) || Map.get(agent_config, "model")
        Synapsis.Providers.model_context_window(provider, model)

      true ->
        model = Map.get(agent_config, :model) || Map.get(agent_config, "model")

        case ModelRegistry.get(model) do
          {:ok, metadata} -> metadata.context_window
          {:error, :unknown} -> nil
        end
    end
  end

  # -- Private --

  defp load_shared_memory_instructions(agent_config, opts) do
    selected = Map.get(agent_config, :tools) || Map.get(agent_config, "tools") || []

    if is_list(selected) and Enum.any?(selected, &(&1 in Synapsis.Memory.HostAgent.tools())) do
      with {:ok, source} <- Synapsis.Memory.Settings.host_source(),
           {:ok, instructions} <- Synapsis.Memory.HostAgent.instructions(source, timeout: 2_000) do
        session_id = Keyword.get(opts, :session_id)
        context = if is_binary(session_id), do: "\nCurrent session_id: " <> session_id, else: ""
        instructions <> context
      else
        _ -> nil
      end
    end
  end

  defp wrap_layer(:base, content), do: content
  defp wrap_layer(:soul, content), do: "<soul>\n#{content}\n</soul>"
  defp wrap_layer(:identity, content), do: "<user_identity>\n#{content}\n</user_identity>"

  defp wrap_layer(:skill_catalog, content),
    do:
      "<system-reminder>\n<skills_instructions>\n#{content}\n</skills_instructions>\n</system-reminder>"

  defp wrap_layer(:remote_skills, content),
    do: "<backplane_skills>\n#{content}\n</backplane_skills>"

  defp wrap_layer(:skills, content),
    do: "<available_skills>\n#{content}\n</available_skills>"

  defp wrap_layer(:memory, content), do: "<memory>\n#{content}\n</memory>"

  defp wrap_layer(:shared_memory, content),
    do: "<shared_memory_instructions>\n#{content}\n</shared_memory_instructions>"

  defp wrap_layer(:bootstrap, content), do: "<environment>\n#{content}\n</environment>"
  defp wrap_layer(:agent, content), do: "<agent_context>\n#{content}\n</agent_context>"

  defp truncate_description(desc, max_len) do
    if String.length(desc) <= max_len do
      desc
    else
      String.slice(desc, 0, max_len - 1) <> "…"
    end
  end

  defp selected_tool_metadata(%{tool_contract_version: 1, tools: names} = agent_config)
       when is_list(names) do
    display = Map.new(DisplayCatalog.list(), &{&1.name, Map.take(&1, [:name, :description])})

    Enum.flat_map(names, fn name ->
      case Map.fetch(display, name) do
        {:ok, metadata} -> [metadata]
        :error -> captured_mcp_metadata(agent_config, name)
      end
    end)
  end

  defp selected_tool_metadata(_agent_config), do: []

  defp captured_mcp_metadata(agent_config, "mcp::" <> qualified = name) do
    with [id, raw_name] <- String.split(qualified, "::", parts: 2),
         sources when is_map(sources) <- agent_config[:mcp_sources],
         %{source_id: ^id, tools: tools} when is_list(tools) <- sources[id],
         %{description: description} <-
           Enum.find(tools, fn
             %{raw_name: ^raw_name} -> true
             _ -> false
           end) do
      [%{name: name, description: description}]
    else
      _ -> []
    end
  end

  defp captured_mcp_metadata(_agent_config, _name), do: []

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_nil(_value), do: nil

  defp build_skill_catalog(agent_config, model_context_window) do
    catalog =
      Map.get(agent_config, :skill_catalog) || Map.get(agent_config, "skill_catalog") || []

    discovery = agent_config[:remote_skill_discovery] || %{sources: [], errors: %{}}
    discovery_ids = Enum.map(discovery.sources, & &1.id) ++ Map.keys(discovery.errors)

    catalog =
      Enum.reject(catalog, &(&1.authority == :backplane and &1.source_id in discovery_ids))

    if catalog == [] do
      nil
    else
      settings =
        Map.get(agent_config, :skill_settings) || Map.get(agent_config, "skill_settings") || %{}

      max_tokens = Map.get(settings, "max_context_tokens", Map.get(settings, :max_context_tokens))

      SkillCatalog.render(catalog,
        max_context_tokens: max_tokens,
        model_context_window: model_context_window
      ).text
    end
  end

  defp build_remote_skills(agent, context_window) do
    case agent[:remote_skill_discovery] do
      %{sources: sources, errors: errors} when sources != [] or map_size(errors) > 0 ->
        guidance =
          "Search Backplane sources with synapsis::skills_search and source_id. Read only assigned results with their exact locator. Unassigned results require the user to assign the skill in Agent settings."

        source_text =
          Enum.map_join(sources, "\n", fn source ->
            partial = if source.partial, do: " (partial catalog)", else: ""
            "Backplane source #{source.name} (source_id #{source.id})#{partial}"
          end)

        catalog =
          sources
          |> Enum.flat_map(& &1.entries)
          |> SkillCatalog.render(model_context_window: context_window)

        failures =
          Enum.map_join(errors, "\n", fn {id, code} ->
            "Backplane source #{id} discovery unavailable (#{code})."
          end)

        Enum.join([guidance, source_text, catalog.text, failures], "\n")

      _ ->
        nil
    end
  end

  defp default_base_prompt do
    """
    You are an AI coding assistant. Follow instructions precisely.
    Use tools when available. Be concise and direct.
    """
  end
end
