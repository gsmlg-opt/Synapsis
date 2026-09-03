defmodule Synapsis.Tool.Gateway do
  @moduledoc """
  Single tool execution gateway (Track C).

  Ordinary callers must go through `execute/3` or `execute_authorized/4`.
  Effects run only after a validated `Capability.Grant`.
  """

  require Logger

  alias Synapsis.Tool.Capability.{Grant, PolicySnapshot}
  alias Synapsis.Tool.CapabilityPolicy
  alias Synapsis.Tool.Executor

  @type execute_result :: {:ok, term()} | {:error, term()}

  @doc """
  Authorize and execute a tool.

  Required context:
  - `:policy_snapshot` or enough info to build one (`:permission_mode` / `:tool_profile`)
  - `:session_id` and/or `:run_id` (fail closed if both missing)

  Optional:
  - `:operator_approval` — when true, elevates `approval_required` to an
    operator-minted grant (never elevates `:deny`)
  - `:attended?` — defaults from snapshot / true when session present
  """
  @spec execute(String.t(), map(), map()) :: execute_result()
  def execute(tool_name, input, context)
      when is_binary(tool_name) and is_map(input) and is_map(context) do
    with {:ok, snapshot} <- resolve_snapshot(context),
         {:ok, grant} <- authorize(tool_name, input, snapshot, context) do
      execute_authorized(tool_name, input, context, grant)
    end
  end

  @doc "Execute a tool with a previously minted, validated grant."
  @spec execute_authorized(String.t(), map(), map(), Grant.t()) :: execute_result()
  def execute_authorized(tool_name, input, context, %Grant{} = grant)
      when is_binary(tool_name) and is_map(input) and is_map(context) do
    context = Map.put(context, :input, input)

    with :ok <- Grant.validate(grant, tool_name, context) do
      Executor.dispatch_granted(tool_name, input, context)
    end
  end

  @doc "Authorize without executing; returns a grant or a structured error."
  @spec authorize(String.t(), map(), PolicySnapshot.t(), map()) ::
          {:ok, Grant.t()} | {:error, term()}
  def authorize(tool_name, input, %PolicySnapshot{} = snapshot, context) do
    context = Map.put(context, :input, input)

    case CapabilityPolicy.evaluate(%{name: tool_name, input: input}, snapshot, context) do
      {:allow, %Grant{} = grant} ->
        {:ok, grant}

      {:approval_required, _req} ->
        if context[:operator_approval] in [true, :approved] do
          {:ok,
           Grant.mint(
             tool_name: tool_name,
             permission_level: CapabilityPolicy.permission_level(tool_name),
             source: :operator_approval,
             session_id: snapshot.session_id || context[:session_id],
             run_id: snapshot.run_id || context[:run_id],
             input: input
           )}
        else
          if snapshot.attended? == false do
            {:error, :approval_unavailable}
          else
            {:error, :requires_approval}
          end
        end

      {:deny, reason} ->
        {:error, reason}
    end
  end

  @doc "Build or fetch a policy snapshot from execution context."
  @spec resolve_snapshot(map()) :: {:ok, PolicySnapshot.t()} | {:error, atom()}
  def resolve_snapshot(context) when is_map(context) do
    cond do
      match?(%PolicySnapshot{}, context[:policy_snapshot]) ->
        {:ok, context[:policy_snapshot]}

      is_atom(context[:tool_profile]) or is_binary(context[:tool_profile]) ->
        {:ok,
         PolicySnapshot.for_profile(context[:tool_profile],
           attended?: Map.get(context, :attended?, context[:tool_profile] in [:coding, "coding"]),
           session_id: context[:session_id],
           run_id: context[:run_id],
           capability_overrides: context[:capability_overrides] || %{}
         )}

      true ->
        mode = context[:permission_mode] || infer_permission_mode(context)

        {:ok,
         PolicySnapshot.from_permission_mode(mode,
           attended?: Map.get(context, :attended?, true),
           session_id: context[:session_id],
           run_id: context[:run_id],
           capability_overrides: context[:capability_overrides] || %{}
         )}
    end
  end

  defp infer_permission_mode(context) do
    case context[:session_id] do
      nil ->
        "ask"

      session_id ->
        config = Synapsis.Tool.Permission.session_config(session_id)

        case config do
          %{mode: :autonomous} -> "yolo"
          %{allow_destructive: :ask, allow_write: :ask} -> "restrict"
          _ -> "ask"
        end
    end
  end
end
