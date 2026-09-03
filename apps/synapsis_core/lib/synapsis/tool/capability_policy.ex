defmodule Synapsis.Tool.CapabilityPolicy do
  @moduledoc """
  Pure capability evaluation boundary (Track C).

  `evaluate/3` never executes tools and has no store/PubSub side effects.
  """

  alias Synapsis.Tool.Capability.{Grant, PolicySnapshot}
  alias Synapsis.Tool.Permission
  alias Synapsis.Tool.Permissions

  @type tool_call :: %{required(:name) => String.t(), optional(:input) => map()}
  @type approval_request :: %{
          tool_name: String.t(),
          permission_level: atom(),
          reason: atom()
        }
  @type decision ::
          {:allow, Grant.t()}
          | {:approval_required, approval_request()}
          | {:deny, atom()}

  @doc """
  Evaluate a tool call against a policy snapshot and execution context.

  Context may include `:session_id`, `:run_id`, and `:input` (for grant digest).
  Missing session/run context fails closed unless `:allow_missing_session` is set
  (test-only / explicitly authorized system paths).
  """
  @spec evaluate(tool_call() | String.t(), PolicySnapshot.t() | nil, map()) :: decision()
  def evaluate(tool_call, snapshot, context \\ %{})

  def evaluate(_tool_call, nil, _context), do: {:deny, :missing_policy_snapshot}

  def evaluate(tool_name, %PolicySnapshot{} = snapshot, context) when is_binary(tool_name) do
    evaluate(%{name: tool_name, input: context[:input] || %{}}, snapshot, context)
  end

  def evaluate(%{name: name} = tool_call, %PolicySnapshot{} = snapshot, context)
      when is_binary(name) do
    input = Map.get(tool_call, :input) || Map.get(tool_call, "input") || %{}

    if missing_required_context?(snapshot, context) do
      {:deny, :missing_session_context}
    else
      decide(name, permission_level(name), input, snapshot, context)
    end
  end

  def evaluate(_, _, _), do: {:deny, :invalid_tool_call}

  @doc "Resolve permission level for a tool name."
  @spec permission_level(String.t()) :: atom()
  def permission_level(tool_name) when is_binary(tool_name) do
    Permission.tool_permission_level(tool_name)
  rescue
    _ -> Permissions.level(tool_name)
  catch
    :exit, _ -> Permissions.level(tool_name)
  end

  defp missing_required_context?(%PolicySnapshot{} = snapshot, context) do
    session_id = snapshot.session_id || context[:session_id]
    run_id = snapshot.run_id || context[:run_id]

    is_nil(session_id) and is_nil(run_id) and context[:allow_missing_session] != true
  end

  defp decide(name, level, input, snapshot, context) do
    decision =
      case override_decision(name, input, snapshot.capability_overrides) do
        {:ok, override} -> override
        :no_match -> level_decision(level, snapshot)
      end

    case decision do
      :allow ->
        {:allow,
         Grant.mint(
           tool_name: name,
           permission_level: level,
           source: :policy_allow,
           session_id: snapshot.session_id || context[:session_id],
           run_id: snapshot.run_id || context[:run_id],
           input: input
         )}

      :approval_required ->
        if snapshot.attended? == false do
          {:deny, :approval_unavailable}
        else
          {:approval_required,
           %{tool_name: name, permission_level: level, reason: :capability_requires_approval}}
        end

      :deny ->
        {:deny, deny_reason(level, snapshot)}
    end
  end

  defp level_decision(level, %PolicySnapshot{} = snapshot) do
    cond do
      level in snapshot.deny_levels -> :deny
      level in snapshot.allow_levels -> :allow
      level in snapshot.approval_levels -> :approval_required
      true -> :deny
    end
  end

  defp deny_reason(level, %PolicySnapshot{deny_levels: deny}) do
    if level in deny, do: :capability_denied, else: :unknown_capability_class
  end

  defp override_decision(tool_name, input, overrides) when is_map(overrides) do
    Enum.find_value(overrides, :no_match, fn {pattern, decision} ->
      if glob_match?(to_string(pattern), tool_name, input) do
        {:ok, normalize_override(decision)}
      end
    end)
  end

  defp override_decision(_, _, _), do: :no_match

  defp normalize_override(v) when v in [:allow, :deny, :ask], do: v
  defp normalize_override("allow"), do: :allow
  defp normalize_override("deny"), do: :deny
  defp normalize_override("ask"), do: :ask
  defp normalize_override("requires_approval"), do: :ask
  defp normalize_override(_), do: :deny

  defp glob_match?(pattern, tool_name, _input) do
    cond do
      pattern == tool_name ->
        true

      String.ends_with?(pattern, "(*)") ->
        prefix = String.trim_trailing(pattern, "(*)")
        String.starts_with?(tool_name, prefix)

      String.contains?(pattern, "*") ->
        regex =
          pattern
          |> Regex.escape()
          |> String.replace("\\*", ".*")
          |> then(&("^" <> &1 <> "$"))

        case Regex.compile(regex) do
          {:ok, re} -> Regex.match?(re, tool_name)
          _ -> false
        end

      true ->
        false
    end
  end
end
