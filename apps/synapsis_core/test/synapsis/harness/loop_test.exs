defmodule Synapsis.Harness.LoopTest do
  use ExUnit.Case, async: true

  alias Synapsis.Harness.{Context, Event, Loop, ProviderEvent}
  alias Synapsis.Harness.Loop.{Broadcast, Effect, Input}

  defp idle_context(attrs \\ []) do
    defaults = [
      provider_request: %{model: "test-model"},
      available_tools: %{
        "read_file" => %{effect_class: :read},
        "write_file" => %{effect_class: :write}
      }
    ]

    Context.new(Keyword.merge(defaults, attrs))
    |> Context.apply_event(
      Event.session_created("session-1",
        agent_id: "main",
        metadata: %{cwd: "/tmp/workspace"}
      )
    )
  end

  defp start_prompt(context \\ idle_context()) do
    Loop.step(context, %Input.UserPrompt{
      message_id: "message-user",
      parts: [%{id: "part-user", type: :text, data: %{content: "hello"}}]
    })
  end

  defp start_provider_step(context) do
    Loop.step(context, %Input.ProviderEvent{
      event: %ProviderEvent.StepStart{step_id: "step-1", model_id: "test-model"}
    })
  end

  describe "user prompts" do
    test "append the user message and request a provider stream from idle context" do
      {:ok, result} = start_prompt()

      assert result.next == :await_provider
      assert [%Event.MessageAppended{}, %Event.PartAppended{}] = result.events
      assert [%Effect.StartProviderStream{request: request}] = result.effects
      assert [%Broadcast.StatusChanged{status: :generating}] = result.broadcasts

      assert request.model == "test-model"
      assert result.context.status == :generating

      assert [%{id: "message-user", role: :user, parts: [%{id: "part-user"}]}] =
               result.context.messages
    end

    test "rejects new prompts while a turn is already active" do
      {:ok, result} = start_prompt()

      assert {:error, :session_busy} =
               Loop.step(result.context, %Input.UserPrompt{message_id: "m2", parts: []})
    end
  end

  describe "provider text turns" do
    test "accumulates streaming deltas and finalizes the assistant part on end_turn" do
      {:ok, prompt_result} = start_prompt()
      {:ok, step_result} = start_provider_step(prompt_result.context)

      assert Enum.any?(step_result.events, &match?(%Event.StepStarted{step_id: "step-1"}, &1))
      assert step_result.context.current_step.step_id == "step-1"

      {:ok, delta_result} =
        Loop.step(step_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.TextDelta{part_id: "part-text", fragment: "hello"}
        })

      assert Enum.any?(delta_result.events, fn
               %Event.PartAppended{part: %{id: "part-text", type: :text}} -> true
               _event -> false
             end)

      assert [%Broadcast.TextDelta{part_id: "part-text", fragment: "hello"}] =
               delta_result.broadcasts

      {:ok, finish_result} =
        Loop.step(delta_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.StepFinish{
            step_id: "step-1",
            stop_reason: :end_turn,
            usage: %{input_tokens: 1, output_tokens: 2}
          }
        })

      assert finish_result.next == :await_user
      assert Enum.any?(finish_result.events, &match?(%Event.StepFinished{step_id: "step-1"}, &1))

      assert Enum.any?(finish_result.events, fn
               %Event.PartUpdated{
                 part_id: "part-text",
                 patch: %{data: %{content: "hello", state: :completed}}
               } ->
                 true

               _event ->
                 false
             end)

      assert finish_result.context.status == :idle
      assert finish_result.context.current_step == nil
      assert finish_result.context.accumulating_parts == %{}
    end
  end

  describe "tool turns" do
    test "starts auto-approved tool calls and resumes provider streaming after the result" do
      {:ok, prompt_result} = start_prompt()
      {:ok, step_result} = start_provider_step(prompt_result.context)

      {:ok, tool_start_result} =
        Loop.step(step_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.ToolCallStart{part_id: "tool-1", tool_name: "read_file"}
        })

      assert Enum.any?(tool_start_result.events, fn
               %Event.PartAppended{part: %{id: "tool-1", type: :tool_call}} -> true
               _event -> false
             end)

      {:ok, args_result} =
        Loop.step(tool_start_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.ToolCallArgsDelta{part_id: "tool-1", fragment: "{\"path\":"}
        })

      assert [%Broadcast.ToolArgsDelta{part_id: "tool-1", fragment: "{\"path\":"}] =
               args_result.broadcasts

      {:ok, complete_result} =
        Loop.step(args_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.ToolCallComplete{part_id: "tool-1", args: %{path: "README.md"}}
        })

      assert [
               %Effect.StartTool{
                 part_id: "tool-1",
                 tool_name: "read_file",
                 args: %{path: "README.md"}
               }
             ] =
               complete_result.effects

      assert complete_result.context.pending_tools["tool-1"].tool_name == "read_file"

      {:ok, finish_result} =
        Loop.step(complete_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.StepFinish{step_id: "step-1", stop_reason: :tool_use, usage: %{}}
        })

      assert finish_result.next == :await_tools
      assert finish_result.context.status == :executing_tools

      {:ok, tool_result} =
        Loop.step(finish_result.context, %Input.ToolCompleted{
          part_id: "tool-1",
          result: %{content: "file contents"}
        })

      assert tool_result.next == :await_provider

      assert Enum.any?(tool_result.events, fn
               %Event.ToolReturned{part_id: "tool-1", result: %{content: "file contents"}} -> true
               _event -> false
             end)

      assert [%Effect.StartProviderStream{}] = tool_result.effects
      assert tool_result.context.status == :generating
      assert tool_result.context.pending_tools == %{}
    end

    test "requests permission for write-class tool calls before starting them" do
      {:ok, prompt_result} = start_prompt()
      {:ok, step_result} = start_provider_step(prompt_result.context)

      {:ok, tool_start_result} =
        Loop.step(step_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.ToolCallStart{part_id: "tool-2", tool_name: "write_file"}
        })

      {:ok, complete_result} =
        Loop.step(tool_start_result.context, %Input.ProviderEvent{
          event: %ProviderEvent.ToolCallComplete{part_id: "tool-2", args: %{path: "README.md"}}
        })

      assert complete_result.next == :await_permission

      assert [%Effect.RequestPermission{request_id: request_id, effect_class: :write}] =
               complete_result.effects

      assert complete_result.context.pending_permission.request_id == request_id

      {:ok, grant_result} =
        Loop.step(complete_result.context, %Input.PermissionGranted{
          request_id: request_id,
          scope: %{once: true}
        })

      assert grant_result.next == :await_tools

      assert [
               %Effect.StartTool{
                 part_id: "tool-2",
                 tool_name: "write_file",
                 args: %{path: "README.md"}
               }
             ] =
               grant_result.effects

      assert grant_result.context.pending_permission == nil
      assert grant_result.context.pending_tools["tool-2"].tool_name == "write_file"
    end
  end

  describe "interruptions" do
    test "user abort cancels in-flight provider work and halts the turn" do
      {:ok, prompt_result} = start_prompt()

      {:ok, abort_result} =
        Loop.step(prompt_result.context, %Input.UserAbort{reason: :user_cancelled})

      assert abort_result.next == {:halt, :user_cancelled}
      assert [%Event.Aborted{reason: :user_cancelled}] = abort_result.events
      assert [%Effect.CancelProviderStream{}] = abort_result.effects
      assert abort_result.context.status == :aborted
    end

    test "provider errors become durable abort decisions" do
      {:ok, prompt_result} = start_prompt()

      {:ok, error_result} =
        Loop.step(prompt_result.context, %Input.ProviderError{reason: :rate_limited})

      assert error_result.next == {:halt, {:provider_error, :rate_limited}}
      assert [%Event.Aborted{reason: {:provider_error, :rate_limited}}] = error_result.events
      assert error_result.context.status == :aborted
    end

    test "budget ticks halt when the token budget is exhausted" do
      context = idle_context(budgets: %{tokens_used: 10, tokens_max: 10})

      {:ok, result} =
        Loop.step(context, %Input.BudgetTick{wall_clock_now: ~U[2026-05-12 00:00:00Z]})

      assert result.next == {:halt, {:budget_exhausted, :tokens}}
      assert [%Event.Aborted{reason: {:budget_exhausted, :tokens}}] = result.events
      assert result.context.status == :aborted
    end
  end
end
