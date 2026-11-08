defmodule Synapsis.Agent.Tools.PermissionSnapshot do
  @moduledoc """
  Compiles an explicit persisted session permission snapshot into host Policy data.

  `compile/4` takes the raw atom-keyed permission map (or SessionPermission struct),
  trusted scope, exact tool bindings, and a finite list of trusted targets. Scope
  requires `session_id` and the expected `permission_fingerprint` in addition to
  Policy's caller/run/incarnation/catalog identity. Bindings are
  `%{name => %{tool_revision: revision, classify: classifier}}`; targets are
  `%{tool: name, action: action, resource: resource, permission_level: level}`.
  Only explicit read/write/execute/destructive levels are supported. Classifiers
  are retained unchanged and never executed by this compiler. Neither model
  input nor native safety annotations establish a permission level.

  `compile_invocation/4` validates overrides against the complete known catalog,
  then compiles only the current trusted target. That target adds `binding` to
  the target shape above and must retain the exact known binding. Its Policy
  contains only that tool and action/resource decision; future resources need
  their own invocation compilation. Unselected known overrides remain part of
  the complete raw fingerprint and are never discarded before validation.
  Invocation targets may explicitly use `:none` for trusted orchestration;
  its default is `:allow`, with exact tool overrides still taking precedence.
  `compile/4` retains its four explicit permission levels.

  Host-only compound invocation targets replace `permission_level` with
  `permission_levels`, a nonempty unique canonical subset of `[:write,
  :destructive]`. Both keys together are invalid. Each requirement uses the same
  effective setting and whole-tool override precedence as a scalar target.
  Decisions fold deny over ask over allow into one action/resource decision;
  Policy and Approval retain their existing single-decision contract. This
  extension does not change the general scalar `compile/4` API.

  The four allow settings apply equally in interactive and autonomous modes.
  Whole-tool overrides retain the full exact tool name. Legacy `name(*)` syntax
  is accepted only for word-character names, matching the legacy parser; bare
  qualified names remain exact. Overrides outside the exact bindings, narrow
  patterns, overlapping forms, malformed data, and unknown decisions return
  `{:needs_review, reason}`. Callers must deny on that result, never discard a
  restriction and retry with default settings.
  There is no alias translation, store loading, default policy, or approval grant.

  `fingerprint/1` hashes the complete raw map deterministically, normalizing a
  SessionPermission struct to its persisted map. It provides snapshot identity,
  not a monotonic version, live revocation, or ABA detection. Timestamps are not
  treated as versions. The host must supply a trusted expected fingerprint and
  refresh both Policy and readiness scope together when its snapshot changes.
  Resource IDs remain opaque and provide no filesystem containment proof.
  """

  alias Synapsis.Agent.Tools.Readiness

  @settings %{
    read: :allow_read,
    write: :allow_write,
    execute: :allow_execute,
    destructive: :allow_destructive
  }
  @raw_fields [
    :session_id,
    :tool_contract_version,
    :mode,
    :allow_read,
    :allow_write,
    :allow_execute,
    :allow_destructive,
    :tool_overrides
  ]
  @scope_fields [
    :caller,
    :run_id,
    :incarnation,
    :catalog_revision,
    :session_id,
    :permission_fingerprint
  ]

  @spec fingerprint(map()) :: String.t()
  def fingerprint(raw) when is_map(raw) do
    raw
    |> persisted_map()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Validates persisted structure, session identity and supported override syntax.

  This does not establish tool binding/target coverage or grant a permission;
  callers still need `compile/4` or `compile_invocation/4` with trusted bindings
  and targets.
  """
  @spec validate(term(), String.t()) :: :ok | {:needs_review, term()}
  def validate(raw, session_id) when is_map(raw) do
    raw = persisted_map(raw)

    with :ok <- validate_raw(raw),
         true <- nonempty?(session_id) and raw.session_id === session_id,
         {:ok, _} <- compile_overrides(raw.tool_overrides, :unbound) do
      :ok
    else
      false -> {:needs_review, :session_mismatch}
      error -> error
    end
  end

  def validate(_, _), do: {:needs_review, :invalid_permission_snapshot}

  @spec compile(map(), map(), map(), [map()]) :: {:ok, map()} | {:needs_review, term()}
  def compile(raw, scope, bindings, targets)
      when is_map(raw) and is_map(scope) and is_map(bindings) and is_list(targets) do
    raw = persisted_map(raw)

    with :ok <- validate_raw(raw),
         :ok <- validate_scope(raw, scope),
         :ok <- validate_bindings(bindings),
         {:ok, overrides} <- compile_overrides(raw.tool_overrides, bindings),
         {:ok, decisions} <- compile_targets(targets, bindings, raw, overrides) do
      {:ok, %{scope: scope, tools: bindings, decisions: decisions}}
    end
  end

  def compile(_, _, _, _), do: {:needs_review, :invalid_snapshot_inputs}

  @spec compile_invocation(map(), map(), map(), map()) ::
          {:ok, map()} | {:needs_review, term()}
  def compile_invocation(raw, scope, known_bindings, %{tool: name, binding: binding} = target)
      when is_map(raw) and is_map(scope) and is_map(known_bindings) do
    raw = persisted_map(raw)

    with :ok <- validate_raw(raw),
         :ok <- validate_scope(raw, scope),
         :ok <- validate_bindings(known_bindings),
         {:ok, overrides} <- compile_overrides(raw.tool_overrides, known_bindings),
         :ok <- validate_invocation_target(target, known_bindings),
         bindings = %{name => binding},
         {:ok, decisions} <-
           compile_invocation_target(target, bindings, raw, overrides) do
      {:ok, %{scope: scope, tools: bindings, decisions: decisions}}
    end
  end

  def compile_invocation(_, _, _, _), do: {:needs_review, :invalid_snapshot_inputs}

  defp compile_invocation_target(
         %{permission_levels: levels, tool: name, action: action, resource: resource},
         _bindings,
         raw,
         overrides
       ) do
    if nonempty?(action) and nonempty?(resource) do
      decisions =
        Enum.map(levels, fn level ->
          Map.get(overrides, name, Map.fetch!(raw, Map.fetch!(@settings, level)))
        end)

      decision = Enum.find([:deny, :ask, :allow], &(&1 in decisions))
      {:ok, %{{name, action, resource} => decision}}
    else
      {:needs_review, :invalid_or_ambiguous_target}
    end
  end

  defp compile_invocation_target(
         %{permission_level: :none, tool: name, action: action, resource: resource},
         _bindings,
         _raw,
         overrides
       ) do
    if nonempty?(action) and nonempty?(resource),
      do: {:ok, %{{name, action, resource} => Map.get(overrides, name, :allow)}},
      else: {:needs_review, :invalid_or_ambiguous_target}
  end

  defp compile_invocation_target(target, bindings, raw, overrides),
    do: compile_targets([Map.delete(target, :binding)], bindings, raw, overrides)

  defp persisted_map(%Synapsis.SessionPermission{} = raw), do: Map.from_struct(raw)
  defp persisted_map(raw), do: raw

  defp validate_raw(raw) do
    valid =
      not is_struct(raw) and Enum.all?(@raw_fields, &Map.has_key?(raw, &1)) and
        no_string_fields?(raw, @raw_fields ++ [:id, :inserted_at, :updated_at]) and
        raw[:tool_contract_version] === 1 and
        nonempty?(raw[:session_id]) and raw[:mode] in [:interactive, :autonomous] and
        Enum.all?(Map.values(@settings), &(raw[&1] in [:allow, :deny, :ask])) and
        is_map(raw[:tool_overrides]) and not is_struct(raw[:tool_overrides])

    if valid, do: :ok, else: {:needs_review, :invalid_permission_snapshot}
  end

  defp validate_scope(raw, scope) do
    cond do
      not no_string_fields?(scope, @scope_fields) ->
        {:needs_review, :ambiguous_scope}

      not nonempty?(scope[:session_id]) or scope[:session_id] !== raw.session_id ->
        {:needs_review, :session_mismatch}

      not nonempty?(scope[:permission_fingerprint]) or
          scope[:permission_fingerprint] !== fingerprint(raw) ->
        {:needs_review, :fingerprint_mismatch}

      true ->
        case Readiness.check(%{scope: scope, tools: %{}}, %{scope: scope, tools: %{}}) do
          :ok -> :ok
          {:error, reason} -> {:needs_review, reason}
        end
    end
  end

  defp validate_bindings(bindings) when is_struct(bindings),
    do: {:needs_review, :invalid_tool_bindings}

  defp validate_bindings(bindings) do
    valid =
      Enum.all?(bindings, fn
        {name, %{tool_revision: revision, classify: classifier} = binding} ->
          exact_name?(name) and Map.keys(binding) |> Enum.sort() == [:classify, :tool_revision] and
            is_integer(revision) and revision > 0 and is_function(classifier, 1)

        _ ->
          false
      end)

    if valid, do: :ok, else: {:needs_review, :invalid_tool_bindings}
  end

  defp validate_invocation_target(%{tool: name, binding: binding} = target, known_bindings) do
    valid =
      invocation_target_shape?(target) and
        Map.has_key?(known_bindings, name) and Map.fetch!(known_bindings, name) === binding

    if valid, do: :ok, else: {:needs_review, :invalid_or_ambiguous_target}
  end

  defp invocation_target_shape?(%{permission_levels: levels} = target) do
    Enum.sort(Map.keys(target)) == [:action, :binding, :permission_levels, :resource, :tool] and
      is_list(levels) and levels != [] and
      Enum.filter([:write, :destructive], &(&1 in levels)) == levels
  end

  defp invocation_target_shape?(target),
    do: Enum.sort(Map.keys(target)) == [:action, :binding, :permission_level, :resource, :tool]

  defp compile_overrides(raw, bindings) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {spec, decision}, {:ok, overrides} ->
      with {:ok, name} <- override_name(spec),
           {:ok, decision} <- override_decision(decision),
           true <- bindings === :unbound or Map.has_key?(bindings, name),
           false <- Map.has_key?(overrides, name) do
        {:cont, {:ok, Map.put(overrides, name, decision)}}
      else
        false -> {:halt, {:needs_review, {:unbound_override, spec}}}
        true -> {:halt, {:needs_review, {:overlapping_overrides, spec}}}
        error -> {:halt, error}
      end
    end)
  end

  defp override_name(spec) when is_binary(spec) do
    case Regex.run(~r/^(\w+)\(\*\)$/, spec) do
      [_, name] ->
        {:ok, name}

      nil ->
        if exact_name?(spec),
          do: {:ok, spec},
          else: {:needs_review, {:unsupported_override, spec}}
    end
  end

  defp override_name(_), do: {:needs_review, :invalid_override_name}

  defp override_decision(value) when value in [:allow, :allowed, "allow", "allowed"],
    do: {:ok, :allow}

  defp override_decision(value) when value in [:deny, :denied, "deny", "denied"], do: {:ok, :deny}

  defp override_decision(value)
       when value in [:ask, :requires_approval, "ask", "requires_approval"],
       do: {:ok, :ask}

  defp override_decision(_), do: {:needs_review, :unsupported_override_decision}

  defp compile_targets(targets, bindings, raw, overrides) do
    result =
      Enum.reduce_while(targets, {:ok, %{}}, fn target, {:ok, decisions} ->
        case target do
          %{tool: name, action: action, resource: resource, permission_level: level}
          when is_map_key(@settings, level) ->
            key = {name, action, resource}

            if Map.keys(target) |> Enum.sort() == [:action, :permission_level, :resource, :tool] and
                 Map.has_key?(bindings, name) and nonempty?(action) and nonempty?(resource) and
                 not Map.has_key?(decisions, key) do
              decision = Map.get(overrides, name, Map.fetch!(raw, Map.fetch!(@settings, level)))
              {:cont, {:ok, Map.put(decisions, key, decision)}}
            else
              {:halt, {:needs_review, :invalid_or_ambiguous_target}}
            end

          _ ->
            {:halt, {:needs_review, :unsupported_target}}
        end
      end)

    with {:ok, decisions} <- result do
      covered = decisions |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      if covered == Enum.sort(Map.keys(bindings)),
        do: {:ok, decisions},
        else: {:needs_review, :missing_tool_targets}
    end
  end

  defp no_string_fields?(map, fields),
    do: Enum.all?(fields, &(not Map.has_key?(map, Atom.to_string(&1))))

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp exact_name?(value),
    do: nonempty?(value) and not String.contains?(value, ["(", ")", "*", "?"])
end
