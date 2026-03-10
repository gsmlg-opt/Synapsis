defmodule Synapsis.Tool.Registry do
  @moduledoc """
  ETS-backed tool definition registry supporting dual dispatch.

  Entries are stored as:
  - `{name, {:module, module, opts}}` for module-based tools
  - `{name, {:process, pid, opts}}` for process-based tools (plugins)

  ## Extended opts keys

  Beyond the original `:timeout`, `:description`, `:parameters`, registration now
  supports:

  - `:deferred` (boolean) — tool is lazy-loaded; excluded from `list_for_llm/1`
    until `mark_loaded/1` is called.
  - `:loaded` (boolean) — internal flag set by `mark_loaded/1`.
  - `:category` (atom) — overrides the module's `category/0` callback.
  - `:permission_level` (atom) — overrides the module's `permission_level/0` callback.
  - `:version` (string) — overrides the module's `version/0` callback.
  - `:enabled` (boolean) — overrides the module's `enabled?/0` callback.
  """
  use GenServer

  @table :synapsis_tools

  @plan_excluded_levels [:write, :execute, :destructive]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Register a module-based tool.

  Opts may include `:deferred`, `:category`, `:permission_level`, `:version`,
  `:enabled`, `:timeout`, `:description`, `:parameters`.  When a key is not
  provided in opts, the value is read from the module's callback at registration
  time and merged into the stored opts.
  """
  def register_module(name, module, opts \\ []) do
    enriched = enrich_opts_from_module(module, opts)
    :ets.insert(@table, {name, {:module, module, enriched}})
    :ok
  end

  @doc "Register a process-based tool (plugin GenServer)."
  def register_process(name, pid, opts \\ []) do
    :ets.insert(@table, {name, {:process, pid, opts}})
    :ok
  end

  @doc "Backward-compatible register from a map with :name, :module, etc."
  def register(tool) when is_map(tool) do
    opts = [
      timeout: tool[:timeout],
      description: tool[:description] || tool.module.description(),
      parameters: tool[:parameters] || tool.module.parameters()
    ]

    extra =
      tool
      |> Map.drop([:name, :module, :description, :parameters, :timeout])
      |> Enum.to_list()

    opts = opts ++ extra

    enriched = enrich_opts_from_module(tool.module, opts)
    :ets.insert(@table, {tool.name, {:module, tool.module, enriched}})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Lookup
  # ---------------------------------------------------------------------------

  @doc "Lookup a tool, returning the dispatch tuple."
  def lookup(tool_name) do
    case :ets.lookup(@table, tool_name) do
      [{^tool_name, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc "Backward-compatible get returning a map format."
  def get(tool_name) do
    case :ets.lookup(@table, tool_name) do
      [{^tool_name, {:module, module, opts}}] ->
        tool = %{
          name: tool_name,
          module: module,
          description: opts[:description] || module.description(),
          parameters: opts[:parameters] || module.parameters(),
          timeout: opts[:timeout]
        }

        {:ok, tool}

      [{^tool_name, {:process, pid, opts}}] ->
        tool = %{
          name: tool_name,
          process: pid,
          description: opts[:description] || "",
          parameters: opts[:parameters] || %{},
          timeout: opts[:timeout]
        }

        {:ok, tool}

      [] ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Listing
  # ---------------------------------------------------------------------------

  @doc """
  List all tools in a format suitable for LLM tool definitions (no filtering).

  This is the original zero-arity version kept for backward compatibility.
  """
  def list_for_llm do
    :ets.tab2list(@table)
    |> Enum.map(&entry_to_llm_map/1)
  end

  @doc """
  List tools for LLM with filtering.

  ## Options

  - `:agent_mode` — `:plan` excludes tools with `permission_level` in
    `#{inspect(@plan_excluded_levels)}`; `:build` (default) includes all.
  - `:include_deferred` — when `false` (default), excludes tools registered
    with `deferred: true` that have not been `mark_loaded/1`-ed.
  - `:categories` — list of category atoms to include.  `nil` means no filter.
  """
  def list_for_llm(filter_opts) when is_list(filter_opts) do
    agent_mode = Keyword.get(filter_opts, :agent_mode, :build)
    include_deferred = Keyword.get(filter_opts, :include_deferred, false)
    categories = Keyword.get(filter_opts, :categories, nil)

    :ets.tab2list(@table)
    |> filter_enabled()
    |> filter_agent_mode(agent_mode)
    |> filter_categories(categories)
    |> filter_deferred(include_deferred)
    |> Enum.map(&entry_to_llm_map/1)
  end

  @doc "List all registered tools matching a given category."
  def list_by_category(category) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_name, entry} ->
      resolve_category_from_entry(entry) == category
    end)
    |> Enum.map(&entry_to_full_map/1)
  end

  @doc "List all registered tools (backward-compatible)."
  def list do
    :ets.tab2list(@table)
    |> Enum.map(&entry_to_full_map/1)
  end

  # ---------------------------------------------------------------------------
  # Deferred loading
  # ---------------------------------------------------------------------------

  @doc """
  Mark a deferred tool as loaded.

  Returns `:ok` on success, or `{:error, :not_found}` if the tool is not
  registered.  No-op (returns `:ok`) if the tool is not deferred.
  """
  def mark_loaded(tool_name) do
    case :ets.lookup(@table, tool_name) do
      [{^tool_name, {kind, ref, opts}}] ->
        updated_opts = Keyword.put(opts, :loaded, true)
        :ets.insert(@table, {tool_name, {kind, ref, updated_opts}})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Unregister
  # ---------------------------------------------------------------------------

  def unregister(tool_name) do
    :ets.delete(@table, tool_name)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, table}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Enrich opts with module callback values where opts don't already specify.
  defp enrich_opts_from_module(module, opts) do
    opts
    |> maybe_put(:category, resolve_category(module, opts))
    |> maybe_put(:permission_level, resolve_permission_level(module, opts))
    |> maybe_put(:version, resolve_version(module, opts))
    |> maybe_put(:enabled, resolve_enabled(module, opts))
    |> maybe_put(:deferred, Keyword.get(opts, :deferred, false))
    |> maybe_put(:loaded, Keyword.get(opts, :loaded, false))
  end

  defp maybe_put(opts, key, value) do
    Keyword.put_new(opts, key, value)
  end

  defp resolve_category(module, opts) do
    opts[:category] ||
      (function_exported?(module, :category, 0) && module.category()) ||
      :filesystem
  end

  defp resolve_permission_level(module, opts) do
    opts[:permission_level] ||
      (function_exported?(module, :permission_level, 0) && module.permission_level()) ||
      :read
  end

  defp resolve_version(module, opts) do
    opts[:version] ||
      (function_exported?(module, :version, 0) && module.version()) ||
      "1.0.0"
  end

  defp resolve_enabled(module, opts) do
    cond do
      Keyword.has_key?(opts, :enabled) -> opts[:enabled]
      function_exported?(module, :enabled?, 0) -> module.enabled?()
      true -> true
    end
  end

  # --- Entry mapping helpers ---

  defp entry_to_llm_map({name, entry}) do
    case entry do
      {:module, module, opts} ->
        %{
          name: name,
          description: opts[:description] || module.description(),
          parameters: opts[:parameters] || module.parameters()
        }

      {:process, _pid, opts} ->
        %{
          name: name,
          description: opts[:description] || "",
          parameters: opts[:parameters] || %{}
        }
    end
  end

  defp entry_to_full_map({name, entry}) do
    case entry do
      {:module, module, opts} ->
        %{
          name: name,
          module: module,
          description: opts[:description] || module.description(),
          parameters: opts[:parameters] || module.parameters(),
          timeout: opts[:timeout]
        }

      {:process, pid, opts} ->
        %{
          name: name,
          process: pid,
          description: opts[:description] || "",
          parameters: opts[:parameters] || %{},
          timeout: opts[:timeout]
        }
    end
  end

  # --- Filtering pipeline ---

  defp filter_enabled(entries) do
    Enum.filter(entries, fn {_name, entry} ->
      resolve_enabled_from_entry(entry)
    end)
  end

  defp filter_agent_mode(entries, :plan) do
    Enum.reject(entries, fn {_name, entry} ->
      resolve_permission_level_from_entry(entry) in @plan_excluded_levels
    end)
  end

  defp filter_agent_mode(entries, _build), do: entries

  defp filter_categories(entries, nil), do: entries
  defp filter_categories(entries, []), do: entries

  defp filter_categories(entries, categories) when is_list(categories) do
    cat_set = MapSet.new(categories)

    Enum.filter(entries, fn {_name, entry} ->
      MapSet.member?(cat_set, resolve_category_from_entry(entry))
    end)
  end

  defp filter_deferred(entries, true), do: entries

  defp filter_deferred(entries, false) do
    Enum.reject(entries, fn {_name, entry} ->
      opts = entry_opts(entry)
      opts[:deferred] == true && opts[:loaded] != true
    end)
  end

  # --- Entry introspection helpers ---

  defp entry_opts({:module, _module, opts}), do: opts
  defp entry_opts({:process, _pid, opts}), do: opts

  defp resolve_enabled_from_entry({:module, module, opts}) do
    cond do
      Keyword.has_key?(opts, :enabled) -> opts[:enabled]
      function_exported?(module, :enabled?, 0) -> module.enabled?()
      true -> true
    end
  end

  defp resolve_enabled_from_entry({:process, _pid, opts}) do
    Keyword.get(opts, :enabled, true)
  end

  defp resolve_permission_level_from_entry({:module, module, opts}) do
    opts[:permission_level] ||
      (function_exported?(module, :permission_level, 0) && module.permission_level()) ||
      :read
  end

  defp resolve_permission_level_from_entry({:process, _pid, opts}) do
    Keyword.get(opts, :permission_level, :read)
  end

  defp resolve_category_from_entry({:module, module, opts}) do
    opts[:category] ||
      (function_exported?(module, :category, 0) && module.category()) ||
      :filesystem
  end

  defp resolve_category_from_entry({:process, _pid, opts}) do
    Keyword.get(opts, :category, :filesystem)
  end
end
