defmodule Synapsis.Harness.Loop do
  @moduledoc """
  Pure harness session loop reducer.

  The reducer turns a folded `Synapsis.Harness.Context` and one input ADT into a
  new context, durable events, side-effect commands, UI broadcasts, and the next
  command decision. It does not persist, broadcast, call providers, or execute
  tools directly.
  """

  alias Synapsis.Harness.{Context, Event, ProviderEvent}
  alias Synapsis.Harness.Loop.{Broadcast, Effect, Input, NextAction}

  @permission_required_effects [:write, :execute, :destructive, :exec, :network]

  def step(%Context{} = context, %Input.UserPrompt{} = input) do
    cond do
      context.status in [:new, :idle] ->
        append_user_prompt(context, input)

      context.status == :aborted ->
        {:error, :inactive_session}

      true ->
        {:error, :session_busy}
    end
  end

  def step(%Context{} = context, %Input.UserAbort{reason: reason}) do
    effects =
      []
      |> maybe_cancel_provider(context)
      |> cancel_pending_tools(context)

    events = [Event.aborted(context.session_id, reason)]
    context = apply_events(context, events)

    ok(context, NextAction.halt(reason), events, effects, [])
  end

  def step(%Context{} = context, %Input.ProviderError{reason: reason}) do
    reason = {:provider_error, reason}
    events = [Event.aborted(context.session_id, reason)]
    context = apply_events(context, events)

    ok(context, NextAction.halt(reason), events)
  end

  def step(%Context{} = context, %Input.ProviderEvent{event: %ProviderEvent.Error{} = event}) do
    step(context, %Input.ProviderError{reason: event.reason})
  end

  def step(%Context{} = context, %Input.ProviderEvent{event: %ProviderEvent.StepStart{} = event}) do
    message_id = context.assistant_message_id || "assistant-#{event.step_id}"

    message_events =
      if assistant_message_exists?(context, message_id) do
        []
      else
        [
          Event.message_appended(context.session_id, %{
            id: message_id,
            role: :assistant,
            parts: []
          })
        ]
      end

    events =
      message_events ++
        [Event.step_started(context.session_id, event.step_id, event.model_id, message_id)]

    context = apply_events(context, events)

    ok(context, NextAction.await_provider(), events)
  end

  def step(%Context{} = context, %Input.ProviderEvent{
        event: %ProviderEvent.TextDelta{} = event
      }) do
    {context, events} = ensure_accumulating_content_part(context, event.part_id, :text)
    context = append_content_fragment(context, event.part_id, event.fragment)

    ok(context, NextAction.await_provider(), events, [], [
      %Broadcast.TextDelta{part_id: event.part_id, fragment: event.fragment}
    ])
  end

  def step(%Context{} = context, %Input.ProviderEvent{
        event: %ProviderEvent.ReasoningDelta{} = event
      }) do
    {context, events} = ensure_accumulating_content_part(context, event.part_id, :reasoning)
    context = append_content_fragment(context, event.part_id, event.fragment)

    ok(context, NextAction.await_provider(), events, [], [
      %Broadcast.ReasoningDelta{part_id: event.part_id, fragment: event.fragment}
    ])
  end

  def step(%Context{} = context, %Input.ProviderEvent{
        event: %ProviderEvent.ToolCallStart{} = event
      }) do
    {context, events} = ensure_accumulating_tool_part(context, event.part_id, event.tool_name)

    ok(context, NextAction.await_provider(), events)
  end

  def step(%Context{} = context, %Input.ProviderEvent{
        event: %ProviderEvent.ToolCallArgsDelta{} = event
      }) do
    context = append_tool_args_fragment(context, event.part_id, event.fragment)

    ok(context, NextAction.await_provider(), [], [], [
      %Broadcast.ToolArgsDelta{part_id: event.part_id, fragment: event.fragment}
    ])
  end

  def step(%Context{} = context, %Input.ProviderEvent{
        event: %ProviderEvent.ToolCallComplete{} = event
      }) do
    complete_tool_call(context, event.part_id, event.args)
  end

  def step(%Context{} = context, %Input.ProviderEvent{
        event: %ProviderEvent.StepFinish{} = event
      }) do
    finish_provider_step(context, event)
  end

  def step(%Context{} = context, %Input.ProviderEvent{event: %ProviderEvent.Done{}}) do
    ok(context, next_for_status(context), [])
  end

  def step(%Context{} = context, %Input.ToolStarted{}) do
    ok(context, next_for_status(context), [])
  end

  def step(%Context{} = context, %Input.ToolCompleted{} = input) do
    finish_tool(context, input.part_id, {:ok, input.result})
  end

  def step(%Context{} = context, %Input.ToolFailed{} = input) do
    finish_tool(context, input.part_id, {:error, input.error})
  end

  def step(%Context{} = context, %Input.PermissionGranted{} = input) do
    with {:ok, permission} <- fetch_permission(context, input.request_id) do
      tool_call = permission.tool_call

      events = [
        Event.permission_granted(context.session_id, input.request_id),
        Event.part_updated(context.session_id, tool_call.message_id, tool_call.part_id, %{
          data: %{state: :running}
        }),
        Event.tool_invoked(
          context.session_id,
          tool_call.message_id,
          tool_call.part_id,
          tool_call.name,
          tool_call.args
        )
      ]

      context = apply_events(context, events)
      context = %{context | status: :executing_tools}

      effects = [
        %Effect.StartTool{
          part_id: tool_call.part_id,
          tool_name: tool_call.name,
          args: tool_call.args
        }
      ]

      ok(context, NextAction.await_tools(), events, effects)
    end
  end

  def step(%Context{} = context, %Input.PermissionDenied{} = input) do
    with {:ok, permission} <- fetch_permission(context, input.request_id) do
      tool_call = permission.tool_call
      error = %{reason: :permission_denied, request_id: input.request_id}

      events = [
        Event.permission_denied(context.session_id, input.request_id, :permission_denied),
        Event.part_updated(context.session_id, tool_call.message_id, tool_call.part_id, %{
          data: %{state: :denied, error: error}
        }),
        Event.tool_returned(
          context.session_id,
          tool_call.message_id,
          tool_call.part_id,
          {:error, error}
        )
      ]

      context =
        context
        |> apply_events(events)
        |> Map.put(:status, :generating)

      ok(context, NextAction.await_provider(), events, [
        %Effect.StartProviderStream{request: next_provider_input(context)}
      ])
    end
  end

  def step(%Context{} = context, %Input.BudgetTick{}) do
    if token_budget_exhausted?(context) do
      reason = {:budget_exhausted, :tokens}
      events = [Event.aborted(context.session_id, reason)]
      context = apply_events(context, events)

      ok(context, NextAction.halt(reason), events)
    else
      ok(context, next_for_status(context), [])
    end
  end

  def step(%Context{}, input), do: {:error, {:unknown_input, input}}

  def next_provider_input(%Context{} = context) do
    Map.merge(context.provider_request || %{}, %{
      session_id: context.session_id,
      agent_id: context.agent_id,
      messages: context.messages,
      tools: Map.keys(context.available_tools || %{}),
      metadata: context.metadata
    })
  end

  defp append_user_prompt(context, input) do
    events = [
      Event.message_appended(context.session_id, %{id: input.message_id, role: :user, parts: []})
      | Enum.map(input.parts, &Event.part_appended(context.session_id, input.message_id, &1))
    ]

    context =
      context
      |> apply_events(events)
      |> Map.put(:status, :generating)

    ok(
      context,
      NextAction.await_provider(),
      events,
      [%Effect.StartProviderStream{request: next_provider_input(context)}],
      [%Broadcast.StatusChanged{status: :generating}]
    )
  end

  defp complete_tool_call(context, part_id, args) do
    with {:ok, tool_call} <- fetch_accumulating_tool(context, part_id) do
      tool_call = %{tool_call | args: args, state: :complete}
      effect_class = effect_class(context, tool_call.name)

      if effect_class in @permission_required_effects do
        request_permission(context, tool_call, effect_class)
      else
        start_tool(context, tool_call)
      end
    end
  end

  defp request_permission(context, tool_call, effect_class) do
    request_id = "permission-#{tool_call.part_id}"

    events = [
      Event.part_updated(context.session_id, tool_call.message_id, tool_call.part_id, %{
        data: %{args: tool_call.args, state: :awaiting_permission}
      }),
      Event.permission_requested(
        context.session_id,
        request_id,
        tool_call.part_id,
        effect_class,
        tool_call
      )
    ]

    context =
      context
      |> Context.delete_accumulating_part(tool_call.part_id)
      |> apply_events(events)

    effects = [
      %Effect.RequestPermission{
        request_id: request_id,
        tool_call: tool_call,
        effect_class: effect_class
      }
    ]

    ok(context, NextAction.await_permission(), events, effects)
  end

  defp start_tool(context, tool_call) do
    events = [
      Event.part_updated(context.session_id, tool_call.message_id, tool_call.part_id, %{
        data: %{args: tool_call.args, state: :running}
      }),
      Event.tool_invoked(
        context.session_id,
        tool_call.message_id,
        tool_call.part_id,
        tool_call.name,
        tool_call.args
      )
    ]

    context =
      context
      |> Context.delete_accumulating_part(tool_call.part_id)
      |> apply_events(events)

    effects = [
      %Effect.StartTool{
        part_id: tool_call.part_id,
        tool_name: tool_call.name,
        args: tool_call.args
      }
    ]

    ok(context, next_for_status(context), events, effects)
  end

  defp finish_provider_step(context, event) do
    finalize_events = finalization_events(context)

    events =
      finalize_events ++
        [Event.step_finished(context.session_id, event.step_id, event.stop_reason, event.usage)]

    context =
      context
      |> apply_events(events)
      |> clear_finalized_accumulators()

    cond do
      context.pending_permission ->
        context = %{context | status: :awaiting_permission}

        ok(context, NextAction.await_permission(), events, [], [
          %Broadcast.StatusChanged{status: :awaiting_permission}
        ])

      map_size(context.pending_tools) > 0 ->
        context = %{context | status: :executing_tools}

        ok(context, NextAction.await_tools(), events, [], [
          %Broadcast.StatusChanged{status: :executing_tools}
        ])

      event.stop_reason == :tool_use ->
        context = %{context | status: :await_step_decision}
        ok(context, NextAction.await_step_decision(), events)

      true ->
        context = %{context | status: :idle, assistant_message_id: nil}

        ok(context, NextAction.await_user(), events, [], [%Broadcast.StatusChanged{status: :idle}])
    end
  end

  defp finish_tool(context, part_id, result_or_error) do
    with {:ok, tool_call} <- fetch_pending_tool(context, part_id) do
      patch = tool_result_patch(result_or_error)

      events = [
        Event.part_updated(context.session_id, tool_call.message_id, tool_call.part_id, patch),
        Event.tool_returned(
          context.session_id,
          tool_call.message_id,
          tool_call.part_id,
          result_or_error
        )
      ]

      context = apply_events(context, events)

      if map_size(context.pending_tools) == 0 do
        context = %{context | status: :generating}

        ok(
          context,
          NextAction.await_provider(),
          events,
          [%Effect.StartProviderStream{request: next_provider_input(context)}],
          [%Broadcast.StatusChanged{status: :generating}]
        )
      else
        ok(context, NextAction.await_tools(), events)
      end
    end
  end

  defp tool_result_patch({:ok, result}) do
    %{data: %{state: :completed, result: result}}
  end

  defp tool_result_patch({:error, error}) do
    %{data: %{state: :failed, error: error}}
  end

  defp ensure_accumulating_content_part(context, part_id, type) do
    case Map.fetch(context.accumulating_parts, part_id) do
      {:ok, _part} ->
        {context, []}

      :error ->
        message_id = assistant_message_id!(context)

        part = %{
          id: part_id,
          type: type,
          data: %{content: "", state: :streaming}
        }

        event = Event.part_appended(context.session_id, message_id, part)

        context =
          context
          |> apply_events([event])
          |> Context.put_accumulating_part(part_id, %{
            message_id: message_id,
            part_id: part_id,
            type: type,
            data: %{content: "", state: :streaming}
          })

        {context, [event]}
    end
  end

  defp ensure_accumulating_tool_part(context, part_id, tool_name) do
    case Map.fetch(context.accumulating_parts, part_id) do
      {:ok, _part} ->
        {context, []}

      :error ->
        message_id = assistant_message_id!(context)

        part = %{
          id: part_id,
          type: :tool_call,
          data: %{tool_name: tool_name, args_fragment: "", state: :streaming}
        }

        event = Event.part_appended(context.session_id, message_id, part)

        tool_call = %{
          message_id: message_id,
          part_id: part_id,
          type: :tool_call,
          name: tool_name,
          args_fragment: "",
          args: %{},
          state: :streaming
        }

        context =
          context
          |> apply_events([event])
          |> Context.put_accumulating_part(part_id, tool_call)

        {context, [event]}
    end
  end

  defp append_content_fragment(context, part_id, fragment) do
    Context.update_accumulating_part(context, part_id, fn part ->
      update_in(part, [:data, :content], &((&1 || "") <> (fragment || "")))
    end)
  end

  defp append_tool_args_fragment(context, part_id, fragment) do
    Context.update_accumulating_part(context, part_id, fn part ->
      Map.update!(part, :args_fragment, &((&1 || "") <> (fragment || "")))
    end)
  end

  defp finalization_events(context) do
    context.accumulating_parts
    |> Map.values()
    |> Enum.filter(&(&1.type in [:text, :reasoning]))
    |> Enum.map(fn part ->
      Event.part_updated(context.session_id, part.message_id, part.part_id, %{
        data: %{content: part.data.content, state: :completed}
      })
    end)
  end

  defp clear_finalized_accumulators(context) do
    accumulating_parts =
      Map.reject(context.accumulating_parts, fn {_part_id, part} ->
        part.type in [:text, :reasoning]
      end)

    %{context | accumulating_parts: accumulating_parts}
  end

  defp fetch_accumulating_tool(context, part_id) do
    case Map.fetch(context.accumulating_parts, part_id) do
      {:ok, %{type: :tool_call} = tool_call} -> {:ok, tool_call}
      {:ok, _part} -> {:error, {:not_a_tool_call, part_id}}
      :error -> {:error, {:unknown_tool_call, part_id}}
    end
  end

  defp fetch_pending_tool(context, part_id) do
    case Map.fetch(context.pending_tools, part_id) do
      {:ok, tool_call} -> {:ok, tool_call}
      :error -> {:error, {:unknown_tool_call, part_id}}
    end
  end

  defp fetch_permission(context, request_id) do
    case context.pending_permission do
      %{request_id: ^request_id, tool_call: %{}} = permission -> {:ok, permission}
      %{request_id: ^request_id} -> {:error, {:missing_permission_tool_call, request_id}}
      _permission -> {:error, {:unknown_permission, request_id}}
    end
  end

  defp effect_class(context, tool_name) do
    tool = context.available_tools |> Map.get(tool_name, %{})

    Map.get(tool, :effect_class, Map.get(tool, "effect_class", :read))
  end

  defp token_budget_exhausted?(context) do
    tokens_max = Map.get(context.budgets, :tokens_max)
    tokens_used = Map.get(context.budgets, :tokens_used, 0)

    is_integer(tokens_max) and tokens_used >= tokens_max
  end

  defp assistant_message_exists?(context, message_id) do
    Enum.any?(context.messages, &match?(%{id: ^message_id, role: :assistant}, &1))
  end

  defp assistant_message_id!(%Context{assistant_message_id: message_id})
       when is_binary(message_id) do
    message_id
  end

  defp assistant_message_id!(%Context{current_step: %{message_id: message_id}})
       when is_binary(message_id) do
    message_id
  end

  defp maybe_cancel_provider(effects, context) do
    if context.status == :generating or context.current_step do
      [%Effect.CancelProviderStream{} | effects]
    else
      effects
    end
  end

  defp cancel_pending_tools(effects, context) do
    context.pending_tools
    |> Map.keys()
    |> Enum.reduce(effects, fn part_id, effects ->
      [%Effect.CancelTool{part_id: part_id} | effects]
    end)
    |> Enum.reverse()
  end

  defp next_for_status(%Context{status: :idle}), do: NextAction.await_user()
  defp next_for_status(%Context{status: :generating}), do: NextAction.await_provider()
  defp next_for_status(%Context{status: :executing_tools}), do: NextAction.await_tools()
  defp next_for_status(%Context{status: :awaiting_permission}), do: NextAction.await_permission()

  defp next_for_status(%Context{status: :await_step_decision}),
    do: NextAction.await_step_decision()

  defp next_for_status(%Context{status: :aborted}), do: NextAction.halt(:aborted)
  defp next_for_status(_context), do: NextAction.await_user()

  defp apply_events(context, events) do
    Enum.reduce(events, context, &Context.apply_event/2)
  end

  defp ok(context, next, events, effects \\ [], broadcasts \\ []) do
    {:ok,
     %{
       context: context,
       next: next,
       events: events,
       effects: effects,
       broadcasts: broadcasts
     }}
  end
end
