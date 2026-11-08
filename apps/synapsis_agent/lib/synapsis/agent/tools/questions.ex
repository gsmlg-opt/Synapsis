defmodule Synapsis.Agent.Tools.Questions do
  @moduledoc """
  Free-text questions using native Conversation interactions.

  Native interactive controls require choices for synchronous questions. This
  host descriptor preserves Synapsis' optional choices and free-text reply using
  the same native interaction, persistence, deadline pause and cancellation.
  Only the primary interactive session can ask. Access to the UI/API identifies
  the trusted operator; no model-supplied identity grants permission.

  The five-minute absolute expiry is checked on answer and after waiting, with
  no background expiry timer. The native run can be explicitly cancelled. The
  complete permission fingerprint is rechecked before returning the answer.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Conversation, Error, InputSchema, ToolEffects}
  alias Synapsis.Agent.Tools.{Approval, PermissionSnapshot}
  alias Synapsis.Session.Store

  @name "synapsis::ask_user"
  @keys ~w(session_id run_id incarnation catalog_revision primary? permission_fingerprint)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: [@name]

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: 1,
           description:
             "Ask the user a question, optionally with choices, and wait for a free-text response. Available only to the primary interactive session.",
           schema: schema(),
           backend: __MODULE__,
           backend_context: context,
           safety: %{read_only: false, retry_safe: false, parallel_safe: false}
         }
       ]}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         true <- context.primary?,
         true <- operation[:tool_name] === @name and operation[:tool_revision] === 1,
         true <-
           Synapsis.Agent.Tools.CatalogBinding.host(
             context,
             operation,
             __MODULE__,
             1,
             @native_keys
           ) === :ok,
         {:ok, _} <- InputSchema.validate(schema(), operation[:arguments]),
         :ok <- current_permission(context) do
      {:ok, %{action: "session.question", resource: "session:" <> context.session_id <> ":user"}}
    else
      false -> failure(:forbidden)
      error -> error
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with true <- is_map(enriched) and Map.keys(enriched) -- (@keys ++ @native_keys) == [],
         context = Map.take(enriched, @keys),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         interact when is_function(interact, 1) <- enriched[:interact] do
      expiry = System.system_time(:millisecond) + 300_000

      scope =
        context
        |> Map.drop([:primary?])
        |> Map.merge(Map.take(operation, [:run_id, :incarnation, :catalog_revision]))
        |> Map.put(:requester_id, Approval.operator_id())

      original =
        Map.take(operation, [
          :run_id,
          :incarnation,
          :catalog_revision,
          :tool_name,
          :tool_revision,
          :invocation_id,
          :tool_call_id,
          :arguments,
          :input_kind
        ])

      request = %{kind: :user_question, scope: scope, operation: original, expires_at: expiry}

      with {:ok, response} <- interact.(request) do
        # The interaction has settled and no answer-dependent effect has run.
        # A revoked/expired answer is a known failure, not uncertain dispatch.
        case accepted_response(context, response, expiry) do
          :ok -> {:ok, %{content: response, structured: %{answer: response}}}
          {:error, error} -> {:ok, %{is_error: true, error: error}}
        end
      end
    else
      {:error, error} ->
        ToolEffects.reject(operation, error)

      _ ->
        {:error, error} = failure(:forbidden)
        ToolEffects.reject(operation, error)
    end
  end

  def execute(_), do: failure(:validation)

  @impl true
  def cancel(_), do: :ok

  def resolve(pid, id, response, %{scope: scope, operation: operation})
      when is_pid(pid) and is_binary(id) and is_map(scope) and is_map(operation) do
    status = Conversation.status(pid)

    with :ok <- valid_response(response),
         %{
           id: ^id,
           request: %{kind: :user_question, scope: ^scope, operation: ^operation} = request
         } <- status.conversation.pending_interaction,
         true <- scope[:requester_id] === Approval.operator_id(),
         true <-
           operation[:run_id] === status.run.run_id and
             operation[:incarnation] === status.run.incarnation and
             operation[:catalog_revision] === status.catalog_revision,
         true <-
           Enum.all?([:run_id, :incarnation, :catalog_revision], &(scope[&1] === operation[&1])),
         :ok <- unexpired(request.expires_at) do
      Conversation.resolve(pid, id, response)
    else
      {:error, _} = error -> error
      _ -> failure(:forbidden)
    end
  catch
    :exit, _ -> failure(:resource_conflict)
  end

  def resolve(_, _, _, _), do: failure(:validation)

  def public_question(%{
        interaction_id: id,
        request: %{kind: :user_question, operation: operation}
      }),
      do: %{
        ref: id,
        question: operation.arguments["question"],
        options: operation.arguments["options"]
      }

  defp context_valid(context) when is_map(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@keys) and
         match?({:ok, _}, Ecto.UUID.cast(context[:session_id])) and
         is_binary(context[:run_id]) and String.valid?(context.run_id) and
         byte_size(context.run_id) in 1..4096 and not String.contains?(context.run_id, "\0") and
         Enum.all?(
           [:incarnation, :catalog_revision],
           &(is_integer(context[&1]) and context[&1] > 0)
         ) and
         is_boolean(context[:primary?]) and is_binary(context[:permission_fingerprint]) and
         byte_size(context.permission_fingerprint) == 64,
       do: :ok,
       else: failure(:validation)
  end

  defp context_valid(_), do: failure(:validation)

  defp current_permission(context) do
    raw = Store.get_value(context.session_id, "permission", nil)

    if PermissionSnapshot.validate(raw, context.session_id) == :ok and
         Map.get(raw, :mode) === :interactive and
         PermissionSnapshot.fingerprint(raw) === context.permission_fingerprint,
       do: :ok,
       else: failure(:forbidden)
  end

  defp valid_response(response) do
    if is_binary(response) and String.valid?(response) and String.trim(response) != "" and
         byte_size(response) <= 32_768,
       do: :ok,
       else: failure(:validation)
  end

  defp accepted_response(context, response, expiry) do
    with :ok <- valid_response(response),
         :ok <- unexpired(expiry),
         do: current_permission(context)
  end

  defp unexpired(expiry) do
    if is_integer(expiry) and System.system_time(:millisecond) <= expiry,
      do: :ok,
      else: failure(:timeout)
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["question"],
      "properties" => %{
        "question" => %{"type" => "string", "minLength" => 1, "maxLength" => 8192},
        "options" => %{
          "type" => "array",
          "maxItems" => 20,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["label"],
            "properties" => %{
              "label" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
              "description" => %{"type" => "string", "maxLength" => 2048}
            }
          }
        }
      }
    }
  end

  defp failure(class),
    do: {:error, Error.new(class, "User question is unavailable, invalid or no longer current")}
end
