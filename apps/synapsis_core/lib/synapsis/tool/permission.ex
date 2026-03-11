defmodule Synapsis.Tool.Permission do
  @moduledoc """
  Tool permission checking with per-session configuration, glob overrides,
  and mode-aware resolution.

  ## Resolution order (3 steps)

  1. **Per-tool glob overrides** — if a matching override exists in the session
     config, its decision wins immediately.
  2. **Permission level vs session config** — the tool's permission level is
     checked against the session's mode and allow_* settings.
  3. **Default policy** — `:requires_approval`.

  ## Return values

  - `:allowed`             — tool may proceed without user interaction
  - `:denied`              — tool is blocked
  - `:requires_approval`   — user must approve before execution
  """

  alias Synapsis.Tool.Permission.SessionConfig

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Check permission for a tool invocation (new 3-arity API).

  `context` is a map that may contain `:session_id`.
  """
  @spec check(String.t(), map(), map()) :: :allowed | :denied | :requires_approval
  def check(tool_name, input, context) do
    session_id = Map.get(context, :session_id)
    config = session_config(session_id)
    do_check(tool_name, input, config)
  end

  @doc """
  Backward-compatible 2-arity check.

  Delegates to `check/3` by extracting a session_id when possible and using
  an empty input map.
  """
  @spec check(String.t(), term()) :: :approved | :denied | :requires_approval
  def check(tool_name, session) do
    session_id = extract_session_id(session)
    config = session_config(session_id)

    case do_check(tool_name, %{}, config) do
      :allowed -> :approved
      :denied -> :denied
      :requires_approval -> :requires_approval
    end
  end

  # ---------------------------------------------------------------------------
  # Session config loading
  # ---------------------------------------------------------------------------

  @doc """
  Load a `SessionConfig` for the given session ID.

  Returns default config when `session_id` is nil or no row exists.
  """
  @spec session_config(binary() | nil) :: SessionConfig.t()
  def session_config(nil), do: SessionConfig.default()

  def session_config(session_id) do
    case Synapsis.Repo.get_by(Synapsis.SessionPermission, session_id: session_id) do
      nil ->
        %SessionConfig{SessionConfig.default() | session_id: session_id}

      row ->
        SessionConfig.from_db(row)
    end
  rescue
    _ ->
      %SessionConfig{SessionConfig.default() | session_id: session_id}
  end

  @doc """
  Upsert session permission configuration in the database.

  `attrs` is a map with keys matching `SessionPermission` fields
  (`:mode`, `:allow_write`, `:allow_execute`, `:allow_destructive`, `:tool_overrides`).
  """
  @spec update_config(binary(), map()) ::
          {:ok, Synapsis.SessionPermission.t()} | {:error, Ecto.Changeset.t()}
  def update_config(session_id, attrs) do
    attrs = Map.put(attrs, :session_id, session_id)

    case Synapsis.Repo.get_by(Synapsis.SessionPermission, session_id: session_id) do
      nil ->
        %Synapsis.SessionPermission{}
        |> Synapsis.SessionPermission.changeset(attrs)
        |> Synapsis.Repo.insert()

      existing ->
        existing
        |> Synapsis.SessionPermission.changeset(attrs)
        |> Synapsis.Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Permission level resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the permission level for a tool by checking (in order):
  1. Registry opts `:permission_level`
  2. Module callback `permission_level/0`
  3. Default `:write`
  """
  @spec tool_permission_level(String.t()) :: atom()
  def tool_permission_level(tool_name) do
    case Synapsis.Tool.Registry.lookup(tool_name) do
      {:ok, {:module, module, opts}} ->
        opts[:permission_level] ||
          (function_exported?(module, :permission_level, 0) && module.permission_level()) ||
          :write

      {:ok, {:process, _pid, opts}} ->
        Keyword.get(opts, :permission_level, :write)

      {:error, :not_found} ->
        :write
    end
  end

  # ---------------------------------------------------------------------------
  # Internal resolution
  # ---------------------------------------------------------------------------

  defp do_check(tool_name, input, %SessionConfig{} = config) do
    # Step 1: Check per-tool glob overrides
    case resolve_override(tool_name, input, config.overrides) do
      {:ok, decision} ->
        decision

      :no_match ->
        # Step 2: Resolve by permission level + session mode
        level = tool_permission_level(tool_name)
        resolve_by_level(level, config)
    end
  end

  # ---------------------------------------------------------------------------
  # Step 1: Glob override resolution
  # ---------------------------------------------------------------------------

  @doc """
  Check overrides list for a matching tool+pattern entry.

  Override format: `%{tool: "bash", pattern: "git *", decision: :allowed}`
  or shorthand string `"bash(git *)"` parsed via `parse_override/1`.

  Returns `{:ok, decision}` or `:no_match`.
  """
  @spec resolve_override(String.t(), map(), list()) :: {:ok, atom()} | :no_match
  def resolve_override(_tool_name, _input, []), do: :no_match

  def resolve_override(tool_name, input, overrides) when is_list(overrides) do
    input_str = select_input_field(tool_name, input)

    overrides
    |> Enum.find_value(fn override ->
      override = normalize_override(override)

      if override.tool == tool_name && glob_match?(override.pattern, input_str) do
        {:ok, override.decision}
      end
    end)
    |> case do
      {:ok, _} = result -> result
      nil -> :no_match
    end
  end

  @doc """
  Parse an override string like `"bash(git *)"` into a map.
  """
  @spec parse_override(String.t()) :: %{tool: String.t(), pattern: String.t()}
  def parse_override(str) when is_binary(str) do
    case Regex.run(~r/^(\w+)\((.+)\)$/, str) do
      [_, tool, pattern] -> %{tool: tool, pattern: pattern}
      nil -> %{tool: str, pattern: "*"}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Level-based resolution
  # ---------------------------------------------------------------------------

  defp resolve_by_level(level, %SessionConfig{mode: :autonomous} = config) do
    case level do
      :none -> :allowed
      :read -> :allowed
      :write -> :allowed
      :execute -> :allowed
      :destructive -> resolve_allow_setting(config.allow_destructive)
    end
  end

  defp resolve_by_level(level, %SessionConfig{mode: :interactive} = config) do
    case level do
      :none -> :allowed
      :read -> :allowed
      :write -> resolve_allow_setting(config.allow_write)
      :execute -> resolve_allow_setting(config.allow_execute)
      :destructive -> resolve_allow_setting(config.allow_destructive)
    end
  end

  defp resolve_allow_setting(true), do: :allowed
  defp resolve_allow_setting(false), do: :denied
  defp resolve_allow_setting(:allow), do: :allowed
  defp resolve_allow_setting(:deny), do: :denied
  defp resolve_allow_setting(:ask), do: :requires_approval
  # Default policy (step 3)
  defp resolve_allow_setting(_), do: :requires_approval

  # ---------------------------------------------------------------------------
  # Input field selection
  # ---------------------------------------------------------------------------

  defp select_input_field("bash", input),
    do: Map.get(input, "command", Map.get(input, :command, ""))

  defp select_input_field("file_read", input),
    do: Map.get(input, "path", Map.get(input, :path, ""))

  defp select_input_field("file_write", input),
    do: Map.get(input, "path", Map.get(input, :path, ""))

  defp select_input_field("file_edit", input),
    do: Map.get(input, "path", Map.get(input, :path, ""))

  defp select_input_field("file_move", input),
    do: Map.get(input, "path", Map.get(input, :path, ""))

  defp select_input_field("file_delete", input),
    do: Map.get(input, "path", Map.get(input, :path, ""))

  defp select_input_field("grep", input),
    do: Map.get(input, "pattern", Map.get(input, :pattern, ""))

  defp select_input_field("glob", input),
    do: Map.get(input, "pattern", Map.get(input, :pattern, ""))

  defp select_input_field(_tool, input) do
    inspect(input)
  end

  # ---------------------------------------------------------------------------
  # Glob matching
  # ---------------------------------------------------------------------------

  defp glob_match?("*", _input), do: true
  defp glob_match?(nil, _input), do: true

  defp glob_match?(pattern, input) when is_binary(pattern) and is_binary(input) do
    regex_str =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("^#{regex_str}$") do
      {:ok, regex} -> String.match?(input, regex)
      _ -> false
    end
  end

  defp glob_match?(_pattern, _input), do: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_override(%{tool: _, pattern: _, decision: _} = override), do: override

  defp normalize_override(%{tool: _, pattern: _} = override) do
    Map.put(override, :decision, :allowed)
  end

  defp normalize_override(str) when is_binary(str) do
    parse_override(str)
    |> Map.put(:decision, :allowed)
  end

  defp extract_session_id(id) when is_binary(id), do: id
  defp extract_session_id(%{id: id}) when is_binary(id), do: id
  defp extract_session_id(%{session_id: id}) when is_binary(id), do: id
  defp extract_session_id(_), do: nil
end
