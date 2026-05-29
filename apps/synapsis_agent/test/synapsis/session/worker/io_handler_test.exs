defmodule Synapsis.Session.Worker.IOHandlerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Runtime.{Graph, Node, Runner}
  alias Synapsis.Session.Worker.IOHandler

  defmodule SlowWaitNode do
    @behaviour Node

    @impl true
    def run(state, ctx) do
      if ctx[:tools_completed] do
        {:end, Map.put(state, :resumed, true)}
      else
        Process.sleep(40)
        {:wait, state}
      end
    end
  end

  test "retries runner resume when a fast tool result arrives before runner waits" do
    graph = %Graph{
      nodes: %{tool_execute: SlowWaitNode},
      edges: %{tool_execute: :end},
      start: :tool_execute
    }

    assert {:ok, runner} = Runner.start_link(graph: graph, state: %{}, ctx: %{})
    state = %{runner_pid: runner, session_id: "test-session"}

    assert {:noreply, ^state} =
             IOHandler.handle_runner_resume(runner, %{tools_completed: true}, 10, state)

    assert eventually_completed(runner)
  end

  defp eventually_completed(runner, attempts \\ 20)

  defp eventually_completed(runner, attempts) when attempts > 0 do
    receive do
      {:runner_resume, ^runner, ctx, remaining_attempts} ->
        IOHandler.handle_runner_resume(
          runner,
          ctx,
          remaining_attempts,
          %{runner_pid: runner, session_id: "test-session"}
        )
    after
      10 ->
        :ok
    end

    case Runner.snapshot(runner) do
      %{status: :completed, state: %{resumed: true}} ->
        true

      _ ->
        eventually_completed(runner, attempts - 1)
    end
  end

  defp eventually_completed(_runner, 0), do: flunk("runner did not complete after resume retry")
end
