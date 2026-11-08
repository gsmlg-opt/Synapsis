defmodule Synapsis.Agent.Tools.AgentCommunication do
  @moduledoc """
  Native adapters for persistent Agent mailbox send, ask, reply and inbox.

  The configured Agent mailbox string and persisted session UUID come only from
  the exact trusted descriptor context. Opaque native run IDs never select a
  mailbox. Native catalog grants, revisions and the host permission gate remain
  required for every operation, including the legacy `:none` permission level.

  The reviewed core domain owns bounded input/output, persistence, atomic reply
  acknowledgement, publication and ask cleanup. This adapter creates no worker
  or deadline override. Execution owns its effect process; the domain's ask
  guardian monitors that caller and expires its open request on cancellation.

  Proven preeffect failures use invocation-bound rejection. Completed failures
  return settled error results with public receipts; uncertain effects remain
  native unknown outcomes with sanitized receipts in host Error details. A
  publication receipt never promises remote delivery or turn activation.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolEffects}
  alias Synapsis.AgentCommunication, as: Domain
  alias Synapsis.Session.Store

  @send "synapsis::agent_send"
  @ask "synapsis::agent_ask"
  @reply "synapsis::agent_reply"
  @inbox "synapsis::agent_inbox"
  @names [@send, @ask, @reply, @inbox]
  @context_keys [:agent_id, :session_id, :primary, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @receipt_keys ~w(code effect message_id request_id response_id ref in_reply_to to
    status request_status publication reply_publication mailbox_publication)a
  @mail_types ~w(request response notification delegation handoff completion)

  def names, do: @names
  def permission_level(name) when name in @names, do: :none

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       Enum.map(@names, fn name ->
         %{
           tool_name: name,
           tool_revision: 1,
           description: description(name),
           schema: schema(name),
           safety: %{read_only: false, retry_safe: false, parallel_safe: false},
           backend: __MODULE__,
           backend_context: context
         }
       end)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation),
         :ok <- primary(context, operation.tool_name) do
      {action, target} =
        case operation.tool_name do
          @send ->
            {"agent.mail.send", %{"to" => operation.arguments["to"]}}

          @ask ->
            {"agent.mail.ask", %{"to" => operation.arguments["to"]}}

          @reply ->
            {"agent.mail.reply", %{"ref" => operation.arguments["ref"]}}

          @inbox ->
            target =
              if operation.arguments["action"] == "thread",
                do: %{"ref" => operation.arguments["ref"]},
                else: %{}

            {"agent.mail.inbox." <> operation.arguments["action"], target}
        end

      scope =
        Map.merge(%{"mailbox" => context.agent_id, "session_id" => context.session_id}, target)

      {:ok, %{action: action, resource: "agent_mail:" <> Jason.encode!(scope)}}
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
         operation = %{original | backend_context: context},
         :ok <- persisted_session(context.session_id) do
      trusted = Map.take(context, [:agent_id, :session_id, :primary])
      settle(original, dispatch(operation.tool_name, operation.arguments, trusted))
    else
      {:error, reason} -> ToolEffects.reject(original, error(reason))
    end
  rescue
    _ -> {:error, error(:unknown_outcome)}
  catch
    :exit, _ -> {:error, error(:unknown_outcome)}
    :throw, _ -> {:error, error(:unknown_outcome)}
  end

  def execute(operation) when is_map(operation),
    do: ToolEffects.reject(operation, error(:invalid_context))

  def execute(_), do: {:error, error(:invalid_context)}

  @impl true
  def cancel(_operation), do: :ok

  defp dispatch(@send, args, context), do: Domain.send(args, context)
  defp dispatch(@ask, args, context), do: Domain.ask(args, context)
  defp dispatch(@reply, args, context), do: Domain.reply(args, context)
  defp dispatch(@inbox, args, context), do: Domain.inbox(args, context)

  defp settle(_operation, {:ok, result}) when is_map(result) do
    {:ok, %{content: Jason.encode!(result), structured: result}}
  end

  defp settle(operation, {:error, %{effect: "none", code: code} = result}) do
    ToolEffects.reject(operation, error(code, receipt(result)))
  end

  defp settle(_operation, {:error, %{effect: "completed", code: code} = result}) do
    public = receipt(result)

    {:ok,
     %{
       is_error: true,
       content: "Agent mailbox operation completed with an error.\n" <> Jason.encode!(public),
       structured: public,
       error: error(code, public)
     }}
  end

  defp settle(_operation, {:error, %{effect: "uncertain"} = result}) do
    {:error, error(:unknown_outcome, receipt(result))}
  end

  defp settle(_, _), do: {:error, error(:unknown_outcome)}

  defp receipt(result), do: Map.take(result, @receipt_keys)

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         opaque?(context[:agent_id], 256) and uuid?(context[:session_id]) and
         is_boolean(context[:primary]) and opaque?(context[:run_id], 4_096) and
         is_integer(context[:incarnation]) and context.incarnation > 0 and
         is_integer(context[:catalog_revision]) and context.catalog_revision > 0,
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

  defp input(%{tool_name: name, arguments: args}) when name in @names do
    with {:ok, _} <- InputSchema.validate(schema(name), args),
         :ok <- Domain.validate(domain_operation(name), args) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp primary(%{primary: false}, @ask), do: {:error, :primary_only}
  defp primary(_, _), do: :ok

  defp persisted_session(id) do
    case Store.get_meta(id) do
      {:ok, %{id: ^id}} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :storage_failed}
    end
  end

  defp uuid?(id) when is_binary(id), do: Ecto.UUID.cast(id) == {:ok, id}
  defp uuid?(_), do: false

  defp opaque?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and
        String.valid?(value) and String.trim(value) != "" and not String.contains?(value, "\0")

  defp domain_operation(@send), do: "send"
  defp domain_operation(@ask), do: "ask"
  defp domain_operation(@reply), do: "reply"
  defp domain_operation(@inbox), do: "inbox"

  defp description(@send),
    do:
      "Persist a notification to a configured Agent mailbox, then publish it. Delivery is not acknowledged."

  defp description(@ask),
    do:
      "Persist a request to an Agent mailbox and wait for a durable response. Primary agents only; bounded timeout."

  defp description(@reply),
    do: "Reply as the request's configured recipient, atomically acknowledging the open request."

  defp description(@inbox),
    do:
      "Read mailbox unread messages, history or a correlation thread; unread retrieval marks returned messages read."

  defp schema(name) do
    {properties, required} =
      case name do
        @send ->
          {%{
             "to" => text_schema(256),
             "content" => text_schema(16_384),
             "type" => %{
               "type" => "string",
               "enum" => ~w(notification info warning),
               "default" => "notification"
             },
             "metadata" => json_object_schema()
           }, ~w(to content)}

        @ask ->
          {%{
             "to" => text_schema(256),
             "question" => text_schema(16_384),
             "context" => json_object_schema(),
             "timeout_ms" => %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 300_000,
               "default" => 120_000
             }
           }, ~w(to question)}

        @reply ->
          {%{
             "ref" => text_schema(256),
             "content" => text_schema(16_384),
             "status" => %{
               "type" => "string",
               "enum" => ~w(success error partial declined),
               "default" => "success"
             }
           }, ~w(ref content)}

        @inbox ->
          {%{
             "action" => %{"type" => "string", "enum" => ~w(unread history thread)},
             "ref" => text_schema(256),
             "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
             "since" => %{"type" => "string"},
             "type" => %{"type" => "string", "enum" => @mail_types}
           }, ["action"]}
      end

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp text_schema(limit), do: %{"type" => "string", "minLength" => 1, "maxLength" => limit}

  defp json_object_schema,
    do: %{
      "type" => "object",
      "additionalProperties" => true,
      "description" => "Portable JSON object, at most 4096 encoded bytes."
    }

  defp error(reason, receipt \\ %{}) do
    code = if is_atom(reason), do: Atom.to_string(reason), else: reason

    class =
      cond do
        code == "unknown_outcome" ->
          :unknown_outcome

        code in ~w(scope_mismatch primary_only not_recipient not_participant) ->
          :forbidden

        code in ~w(invalid_context invalid_input not_request invalid_since invalid_limit) ->
          :validation

        code == "not_found" ->
          :not_found

        code in ~w(request_closed request_expired ambiguous_ref) ->
          :resource_conflict

        code == "timeout" ->
          :timeout

        code == "output_limit" ->
          :budget_exceeded

        true ->
          :execution_failure
      end

    details = %{code: Map.get(receipt, :code, code)}
    details = if receipt == %{}, do: details, else: Map.put(details, :receipt, receipt)
    Error.new(class, "Agent mailbox operation failed", details: details)
  end
end
