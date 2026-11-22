defmodule Synapsis.LocalAgentThreadsTest do
  use Synapsis.DataCase

  alias Synapsis.LocalAgentThreads

  setup do
    clear_coord("coord/local_agents/threads/")
    on_exit(fn -> clear_coord("coord/local_agents/threads/") end)
    :ok
  end

  test "lists an agent's recorded threads newest first, up to the limit" do
    for id <- ["t-1", "QS0x.b", "t-3"], do: :ok = LocalAgentThreads.record("agent-a", id)
    :ok = LocalAgentThreads.record("agent-b", "other")

    assert {:ok, [%{id: "t-3", title: nil, updated_at: at}, %{id: "QS0x.b"}]} =
             LocalAgentThreads.list("agent-a", 2)

    assert {:ok, _, _} = DateTime.from_iso8601(at)
    assert {:ok, [%{id: "other"}]} = LocalAgentThreads.list("agent-b", 10)
  end

  test "an agent with no threads lists none" do
    assert {:ok, []} = LocalAgentThreads.list("agent-none", 10)
  end
end
