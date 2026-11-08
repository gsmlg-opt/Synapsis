defmodule Synapsis.Agent.Tools.ExplicitSkill do
  @moduledoc """
  Native explicit reads of enabled skills in a frozen trusted Agent catalog.

  Retains the legacy locator and unique-name inputs, including locator precedence.
  Manual-only text stays inert and does not become eligible for automatic search
  or read. Native admission and Execution own exact grants and revisions.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.SkillReader
  alias Synapsis.Agent.Tools.{SkillResultContract, Skills}

  @name "synapsis::skill"
  @context_keys [:snapshot, :run_id, :incarnation, :catalog_revision]
  @native_context_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: [@name]
  def permission_level(@name), do: :none

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: 2,
           description:
             "Read the complete assigned or Agent-private learned SKILL.md as inert text by exact locator or unique name, including manual-only skills.",
           schema: %{
             "type" => "object",
             "properties" => %{
               "locator" => %{
                 "type" => "string",
                 "maxLength" => 4096,
                 "description" =>
                   "Exact locator from the Skill catalog; takes precedence over name"
               },
               "name" => %{
                 "type" => "string",
                 "maxLength" => 4096,
                 "description" => "Temporary compatibility lookup by unique skill name"
               }
             },
             "anyOf" => [%{"required" => ["locator"]}, %{"required" => ["name"]}],
             "additionalProperties" => false
           },
           safety: %{read_only: true, retry_safe: true, parallel_safe: true},
           backend: __MODULE__,
           backend_context: context
         }
       ]}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         %{tool_name: @name, arguments: input} <- operation,
         {:ok, binding} <- SkillReader.select_explicit(context.snapshot, input) do
      Skills.read_target(context.snapshot, binding)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_input}
    end
  end

  @impl true
  def execute(%{backend_context: context} = operation) do
    with {:ok, context} <- execution_context(context),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         {:ok, opts} <- Skills.read_options(operation),
         {:ok, public} <- SkillReader.read_explicit(context.snapshot, operation.arguments, opts) do
      {:ok, %{content: SkillResultContract.format_instructions(public), structured: public}}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def execute(_), do: failure(:invalid_input)

  # Execution owns the effect process; the shared domain observes owner loss.
  @impl true
  def cancel(_), do: :ok

  defp execution_context(context) when is_map(context) do
    if Map.keys(context) -- (@context_keys ++ @native_context_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp context_valid(context) when is_map(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         SkillReader.valid_snapshot?(context[:snapshot]) and
         valid_run_id?(context[:run_id]) and is_integer(context[:incarnation]) and
         context.incarnation > 0 and
         is_integer(context[:catalog_revision]) and context.catalog_revision > 0,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp valid_run_id?(run_id) do
    is_binary(run_id) and byte_size(run_id) in 1..4096 and String.valid?(run_id) and
      String.trim(run_id) != "" and not String.contains?(run_id, "\0")
  end

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(
      context,
      operation,
      __MODULE__,
      2,
      @native_context_keys
    )
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp failure(%Error{} = error), do: {:error, error}

  defp failure(reason) do
    class =
      cond do
        reason in [:scope_mismatch, :stale_snapshot, :unsafe_path, :digest_mismatch] ->
          :forbidden

        reason in [:invalid_context, :invalid_input, :ambiguous] ->
          :validation

        reason == :not_found ->
          :not_found

        reason == :timeout ->
          :timeout

        reason in [:candidate_limit, :file_limit, :output_limit, :worker_limit] ->
          :budget_exceeded

        reason == :unavailable ->
          :unsupported_capability

        true ->
          :malformed_result
      end

    {:error, Error.new(class, "skill read failed", details: %{code: Atom.to_string(reason)})}
  end
end
