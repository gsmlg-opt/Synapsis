defmodule Synapsis.Agent.Tools.LLMTask.Completion do
  @moduledoc """
  One isolated, durable native completion inside an admitted tool effect task.

  This internal function must run synchronously in the native supervised effect
  task. The direct Conversation link covers that task's abnormal retirement;
  arbitrary callers deliberately exiting normally are outside this contract.
  The host supplies an already resolved provider context, prepared user input,
  finite limits, actual operation/session binding, durable store and trusted
  caller identity. No model/default/credential selection or tool registration
  happens here. The parent Session binding is never attached to the child.

  The intended locator precedes startup. Registration precedes the single prompt.
  Success requires committed native completion, JSON decoding, confirmed resource
  release and observed child retirement. Uncertain inference is never replayed.
  `observed_metadata` contains only the model retained on that committed assistant
  message; the requested model alias and provider configuration never supply it.
  """

  alias Backplane.AgentRuntime.{Conversation, Error, Goal, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{ProviderAdapter, RunInventory, Store}
  alias Synapsis.Agent.Tools.LLMTask.Result

  @system "You are a JSON-only function. Return ONLY a valid JSON value. Do not wrap in markdown fences. Do not include commentary. Do not call tools."
  @cleanup_timeout 2_000
  @request_options [:model, :max_tokens, :temperature, :reasoning_effort, :thinking_config]

  def run(request, context) when is_map(request) and is_map(context) do
    with :ok <- validate(request, context),
         {:ok, _owner} <- Session.validate(context.session_binding, context.operation),
         {:ok, deadline} <- deadline(request, context.operation),
         identity = %{run_id: Ecto.UUID.generate(), incarnation: context.store.incarnation},
         locator =
           RunInventory.completion(context.session_id, context.store, identity, context.operation),
         :ok <- RunInventory.retain(locator),
         {:ok, options} <- options(request, context, identity, deadline) do
      start(options, request, context.session_binding, locator, deadline)
    end
  end

  def run(_, _), do: failure(:validation, "LLM completion requires request and host context maps")

  defp validate(request, context) do
    with %{
           prompt: prompt,
           provider_context: %{provider_config: config, request_options: options},
           timeout_ms: timeout,
           output_limit: limit
         } <- request,
         true <- is_binary(prompt) and String.valid?(prompt),
         true <- is_map(config) and is_map(options),
         true <- is_binary(options[:model]) and options[:model] != "",
         true <- is_integer(timeout) and timeout in 1..3_600_000,
         true <- is_integer(limit) and limit > 0,
         %{
           operation: %{run_id: run_id, incarnation: incarnation, invocation_id: invocation},
           session_binding: binding,
           store: %{namespace: namespace, incarnation: store_incarnation},
           session_id: session_id,
           caller: caller
         } <- context,
         true <-
           is_map(binding) and is_binary(run_id) and is_integer(incarnation) and
             is_binary(invocation),
         true <- is_binary(namespace) and is_integer(store_incarnation) and store_incarnation > 0,
         true <- is_binary(session_id) and is_binary(caller) and caller != "" do
      :ok
    else
      _ ->
        failure(
          :validation,
          "LLM completion requires explicit input, provider, limits and admitted host context"
        )
    end
  end

  defp deadline(request, operation) do
    case get_in(operation, [:backend_context, :effect_deadline]) do
      callback when is_function(callback, 0) ->
        with {:ok, %{deadline_ms: parent, remaining_ms: remaining, paused: false}} <- callback.(),
             true <-
               is_integer(parent) and is_integer(remaining) and remaining > 0 and parent > now() do
          {:ok, min(parent, now() + request.timeout_ms)}
        else
          {:error, %Error{}} = error ->
            error

          _ ->
            failure(
              :resource_conflict,
              "LLM completion requires an active finite effect deadline"
            )
        end

      _ ->
        failure(:validation, "LLM completion requires the native effect deadline")
    end
  end

  defp options(request, context, identity, deadline) do
    authority = %{
      caller: context.caller,
      run_id: identity.run_id,
      grants: [],
      tool_revisions: %{}
    }

    timeout = max(1, deadline - now())

    provider = %{
      provider_config: request.provider_context.provider_config,
      request_options:
        request.provider_context.request_options
        |> Map.take(@request_options)
        |> Map.put(:system_prompt, @system),
      stream_timeout: timeout,
      output_limit: request.output_limit
    }

    options = [
      run_id: identity.run_id,
      incarnation: identity.incarnation,
      store: Store,
      context: %{namespace: context.store.namespace, incarnation: identity.incarnation},
      provider: ProviderAdapter,
      provider_context: provider,
      subscriber: self(),
      messages: [],
      registry: %ToolRegistry{},
      tools: [],
      hosted_tools: [],
      authority: authority,
      schema_admission: :strict,
      work: 1,
      run_timeout: timeout,
      # Native effect deadlines are monotonic; persisted run deadlines are wall time.
      inherited_deadline: System.system_time(:millisecond) + timeout,
      effect_timeout: timeout,
      commit_timeout: min(timeout, 5_000),
      cleanup_timeout: @cleanup_timeout,
      output_limit: request.output_limit
    ]

    case {context[:goal], context[:goal_binding]} do
      {nil, nil} ->
        {:ok, options}

      {goal, binding} when is_pid(goal) and is_map(binding) ->
        attrs = %{
          thread_id: identity.run_id,
          run_id: identity.run_id,
          incarnation: identity.incarnation,
          authority: authority
        }

        with {:ok, child_binding} <- Goal.delegate(goal, binding, attrs) do
          {:ok,
           options ++
             [goal: goal, goal_binding: child_binding, thread_id: child_binding.thread_id]}
        end

      _ ->
        failure(:validation, "LLM completion Goal requires both goal and binding")
    end
  end

  defp start(options, request, binding, locator, deadline) do
    case Conversation.start_link(options) do
      {:ok, child} ->
        monitor = Process.monitor(child)
        cleanup = fn -> cleanup(child, locator) end

        registration =
          safe(fn ->
            ResourceRegistry.register(
              binding.resource_registry,
              binding.owner_id,
              :llm_task,
              child,
              incarnation: binding.incarnation,
              owner_pid: self(),
              cleanup: cleanup
            )
          end)

        result =
          case registration do
            {:ok, handle} ->
              registered(child, monitor, handle, request, binding, locator, deadline)

            error ->
              case retire(child) do
                :ok ->
                  with :ok <- unbind(options), do: error

                _ ->
                  failure(:unknown_outcome, "Dormant LLM completion retirement is unconfirmed")
              end
          end

        Process.demonitor(monitor, [:flush])
        result

      {:error, _} = error ->
        with :ok <- unbind(options), do: error
    end
  end

  defp registered(child, monitor, handle, request, binding, locator, deadline) do
    result =
      safe(fn ->
        with {:ok, _} <- Conversation.prompt(child, request.prompt),
             :ok <- await(child, monitor, locator, deadline),
             {:ok, status} <- completed(child, locator),
             {:ok, text} <- assistant_text(status.messages),
             {:ok, value} <- Result.decode(text, Map.get(request, :schema)) do
          {:ok,
           %{
             value: value,
             text: text,
             locator: locator,
             usage: List.last(status.conversation.usage),
             observed_metadata: observed_metadata(status.messages)
           }}
        end
      end)

    case safe(fn ->
           ResourceRegistry.release(binding.resource_registry, handle, binding.owner_id)
         end) do
      {:ok, _} ->
        result

      {:error, _} = error ->
        # Registry retains its uncertain inspection record. DOWN here only
        # proves local retirement, never remote cancellation or non-dispatch.
        retire(child)
        error
    end
  end

  defp await(child, monitor, locator, deadline) do
    run_id = locator.run_id
    incarnation = locator.incarnation

    receive do
      {:agent_runtime, ^run_id,
       %{type: :run_completed, run_id: ^run_id, incarnation: ^incarnation}} ->
        :ok

      {:agent_runtime, ^run_id, %{type: type, run_id: ^run_id, incarnation: ^incarnation}}
      when type in [:run_failed, :run_cancelled] ->
        failure(:unknown_outcome, "LLM completion did not complete normally")

      {:agent_runtime, ^run_id, _event} ->
        await(child, monitor, locator, deadline)

      {:DOWN, ^monitor, :process, ^child, _reason} ->
        failure(:unknown_outcome, "LLM completion ended before its committed terminal event")
    after
      max(0, deadline - now()) ->
        failure(:unknown_outcome, "LLM completion terminal observation timed out")
    end
  end

  defp completed(child, locator) do
    case Conversation.status(child) do
      %{
        phase: :terminal,
        run: %{run_id: run_id, incarnation: incarnation, state: :completed},
        resource_cleanup: :confirmed
      } = status
      when run_id == locator.run_id and incarnation == locator.incarnation ->
        {:ok, status}

      _ ->
        failure(:unknown_outcome, "LLM completion terminal cleanup is unconfirmed")
    end
  end

  defp assistant_text(messages) do
    case List.last(messages) do
      %{role: :assistant, content: text} when is_binary(text) ->
        {:ok, text}

      %{role: :assistant, content: blocks} when is_list(blocks) ->
        if Enum.all?(blocks, &match?(%{type: :text, text: text} when is_binary(text), &1)),
          do: {:ok, Enum.map_join(blocks, "", & &1.text)},
          else: failure(:malformed_result, "LLM completion has no committed assistant text")

      _ ->
        failure(:malformed_result, "LLM completion has no committed assistant text")
    end
  end

  defp observed_metadata(messages) do
    case List.last(messages) do
      %{role: :assistant, model: model} when is_binary(model) and model != "" -> %{model: model}
      _ -> %{}
    end
  end

  defp cleanup(child, locator) do
    case safe(fn -> completed(child, locator) end) do
      {:ok, _} ->
        case retire(child) do
          :ok -> :ok
          _ -> {:uncertain, :completion_retirement_unconfirmed}
        end

      _ ->
        safe(fn -> Conversation.cancel(child) end)
        retire(child)
        {:uncertain, :completion_terminal_cleanup_unconfirmed}
    end
  end

  defp retire(child) do
    monitor = Process.monitor(child)
    stopped = safe(fn -> GenServer.stop(child, :normal, @cleanup_timeout) end)

    if stopped != :ok do
      Process.unlink(child)
      Process.exit(child, :kill)
    end

    result =
      receive do
        {:DOWN, ^monitor, :process, ^child, :normal} when stopped == :ok ->
          :ok

        {:DOWN, ^monitor, :process, ^child, _} ->
          {:uncertain, :completion_retired_without_terminal_proof}
      after
        @cleanup_timeout -> {:uncertain, :completion_retirement_unconfirmed}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp unbind(options) do
    if options[:goal] do
      case safe(fn -> Goal.unbind(options[:goal], options[:goal_binding]) end) do
        {:ok, :unbound} -> :ok
        _ -> failure(:unknown_outcome, "LLM completion Goal unbinding is unconfirmed")
      end
    else
      :ok
    end
  end

  defp safe(function) do
    function.()
  rescue
    _ -> failure(:unknown_outcome, "LLM completion operation raised; do not replay")
  catch
    :exit, _ -> failure(:unknown_outcome, "LLM completion operation ended; do not replay")
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
  defp now, do: System.monotonic_time(:millisecond)
end
