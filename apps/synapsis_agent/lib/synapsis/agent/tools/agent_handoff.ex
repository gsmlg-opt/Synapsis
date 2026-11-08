defmodule Synapsis.Agent.Tools.AgentHandoff do
  @moduledoc """
  Native handoff capability for durable mail and a generated Workspace artifact.

  Configured Agent name, session UUID and native scope are trusted descriptor
  context. The Workspace domain owns bounded storage, publication and caller
  cancellation. This adapter does not invoke legacy tools or start an agent.
  Known partial effects settle with receipts; uncertain effects retain the
  native unknown-outcome classification.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolEffects}
  alias Synapsis.AgentCommunication
  alias Synapsis.Workspace.Handoffs

  @name "synapsis::agent_handoff"
  @context_keys [:agent_id, :session_id, :primary, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @receipt_keys ~w(code effect message_id ref to status message_status artifact_path
    artifact_status artifact_content_status artifact_metadata_status mailbox_publication
    workspace_publication session_publication global_publication)a

  def names, do: [@name]
  def permission_level(@name), do: :none

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: 1,
           description:
             "Persist a handoff to an Agent mailbox and a generated own Workspace JSON artifact, then publish notifications. Does not start an agent or acknowledge delivery.",
           schema: schema(),
           safety: %{read_only: false, retry_safe: false, parallel_safe: false},
           backend: __MODULE__,
           backend_context: context
         }
       ]}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      scope = %{
        "mailbox" => context.agent_id,
        "session_id" => context.session_id,
        "to" => operation.arguments["to"],
        "artifact_prefix" => "/agents/#{context.agent_id}/handoffs/"
      }

      {:ok, %{action: "agent.mail.handoff", resource: "agent_handoff:" <> Jason.encode!(scope)}}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = original) do
    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(original, context)
           ),
         operation = %{original | backend_context: context} do
      trusted = Map.take(context, [:agent_id, :session_id, :primary])
      settle(original, Handoffs.handoff(operation.arguments, trusted))
    else
      {:error, reason} -> ToolEffects.reject(original, error(reason))
    end
  rescue
    _ -> {:error, error(:unknown_outcome)}
  catch
    _, _ -> {:error, error(:unknown_outcome)}
  end

  def execute(operation) when is_map(operation),
    do: ToolEffects.reject(operation, error(:invalid_context))

  def execute(_), do: {:error, error(:invalid_context)}

  @impl true
  def cancel(_operation), do: :ok

  defp settle(_operation, {:ok, result}) when is_map(result) do
    receipt = Map.take(result, @receipt_keys)

    {:ok,
     %{
       content:
         "Handoff mail and Workspace artifact persisted; notifications published.\n" <>
           Jason.encode!(receipt),
       structured: receipt
     }}
  end

  defp settle(operation, {:error, %{effect: "none", code: code} = result}),
    do: ToolEffects.reject(operation, error(code, Map.take(result, @receipt_keys)))

  defp settle(_operation, {:error, %{effect: "completed", code: code} = result}) do
    receipt = Map.take(result, @receipt_keys)

    {:ok,
     %{
       is_error: true,
       content:
         "Handoff completed partially; see persistence and publication receipts.\n" <>
           Jason.encode!(receipt),
       structured: receipt,
       error: error(code, receipt)
     }}
  end

  defp settle(_operation, {:error, %{effect: "uncertain"} = result}),
    do: {:error, error(:unknown_outcome, Map.take(result, @receipt_keys))}

  defp settle(_, _), do: {:error, error(:unknown_outcome)}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         opaque?(context[:agent_id], 256) and
         Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, context.agent_id) and
         uuid?(context[:session_id]) and is_boolean(context[:primary]) and
         opaque?(context[:run_id], 4_096) and is_integer(context[:incarnation]) and
         context.incarnation > 0 and is_integer(context[:catalog_revision]) and
         context.catalog_revision > 0,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp execution_context(context) when is_map(context) and not is_struct(context) do
    if Map.keys(context) -- (@context_keys ++ @native_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys)
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: @name, arguments: args}) do
    with {:ok, _} <- InputSchema.validate(schema(), args),
         :ok <- AgentCommunication.validate("handoff", args) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(to summary instructions),
      "properties" => %{
        "to" => text_schema(256),
        "summary" => text_schema(16_384),
        "instructions" => text_schema(16_384),
        "artifacts" => %{
          "type" => "array",
          "items" => text_schema(1024),
          "maxItems" => 64,
          "description" =>
            "Logical @synapsis/ references, retained without reading their content."
        },
        "priority" => %{
          "type" => "string",
          "enum" => ~w(low normal high critical),
          "default" => "normal"
        },
        "constraints" => %{
          "type" => "object",
          "additionalProperties" => true,
          "description" => "Portable JSON object, at most 4096 encoded bytes."
        }
      },
      "description" => "Complete encoded input is at most 61440 bytes."
    }
  end

  defp text_schema(limit), do: %{"type" => "string", "minLength" => 1, "maxLength" => limit}
  defp uuid?(id) when is_binary(id), do: Ecto.UUID.cast(id) == {:ok, id}
  defp uuid?(_), do: false

  defp opaque?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and
        String.valid?(value) and String.trim(value) != "" and not String.contains?(value, "\0")

  defp error(reason, receipt \\ %{}) do
    code = if is_atom(reason), do: Atom.to_string(reason), else: reason

    class =
      case code do
        "unknown_outcome" -> :unknown_outcome
        "scope_mismatch" -> :forbidden
        "unsafe_path" -> :forbidden
        "invalid_context" -> :validation
        "invalid_input" -> :validation
        "not_found" -> :not_found
        "timeout" -> :timeout
        "output_limit" -> :budget_exceeded
        _ -> :execution_failure
      end

    details = %{code: Map.get(receipt, :code, code)}
    details = if receipt == %{}, do: details, else: Map.put(details, :receipt, receipt)
    Error.new(class, "Agent handoff failed", details: details)
  end
end
