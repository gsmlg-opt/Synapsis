defmodule Synapsis.SkillWorkshop.ChangesFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.SkillWorkshop.Changes

  @epoch_ms 1_790_000_000_000

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    agent_id = agent_namespace()
    %{agent_id: agent_id}
  end

  test "empty Agent histories retain source-shaped changes in separate namespaces", %{
    agent_id: agent_id
  } do
    assert Changes.list(agent_id, [], deadline()) == {:ok, []}

    change = change(agent_id, Ecto.UUID.generate(), "create", "agent", @epoch_ms)
    assert Changes.append(change, deadline()) == {:ok, change}

    other_agent = agent_namespace()
    other = change(other_agent, Ecto.UUID.generate(), "create", "agent", @epoch_ms)
    assert Changes.append(other, deadline()) == {:ok, other}

    assert Changes.list(agent_id, [], deadline()) == {:ok, [change]}
    assert Changes.list(other_agent, [], deadline()) == {:ok, [other]}
  end

  test "all six mutation kinds and four actors retain Unicode and optional provenance", %{
    agent_id: agent_id
  } do
    session_key = "agent:#{agent_id}:workshop293"
    run_id = Ecto.UUID.generate()

    changes =
      for {action, actor, ordinal} <- [
            {"create", "agent", 1},
            {"patch", "review", 2},
            {"write_file", "curator", 3},
            {"remove_file", "user", 4},
            {"archive", "agent", 5},
            {"restore", "user", 6}
          ] do
        change =
          change(agent_id, Ecto.UUID.generate(), action, actor, @epoch_ms + ordinal)
          |> Map.merge(%{"sessionKey" => session_key, "runId" => run_id})

        if action == "create",
          do: change,
          else: Map.put(change, "versionId", "20261107T010203004Z-#{action}")
      end

    for change <- changes do
      assert Changes.append(change, deadline()) == {:ok, change}
    end

    assert Changes.list(agent_id, [], deadline()) == {:ok, Enum.reverse(changes)}
  end

  test "timestamps precede insertion order and tied timestamps use newest insertion", %{
    agent_id: agent_id
  } do
    latest = change(agent_id, Ecto.UUID.generate(), "create", "agent", @epoch_ms + 300)

    first_tie =
      change(
        agent_id,
        "ffffffff-ffff-4fff-bfff-ffffffffffff",
        "patch",
        "agent",
        @epoch_ms + 200
      )

    oldest = change(agent_id, Ecto.UUID.generate(), "write_file", "agent", @epoch_ms + 100)

    last_tie =
      change(
        agent_id,
        "00000000-0000-4000-8000-000000000001",
        "remove_file",
        "agent",
        @epoch_ms + 200
      )

    for change <- [latest, first_tie, oldest, last_tie] do
      assert Changes.append(change, deadline()) == {:ok, change}
    end

    assert Changes.list(agent_id, [], deadline()) ==
             {:ok, [latest, last_tie, first_tie, oldest]}
  end

  test "exclusive time and exact run filters apply before the requested page length", %{
    agent_id: agent_id
  } do
    first =
      change(agent_id, Ecto.UUID.generate(), "create", "agent", @epoch_ms + 10)
      |> Map.put("runId", "run-293-a")

    other_run =
      change(agent_id, Ecto.UUID.generate(), "patch", "agent", @epoch_ms + 20)
      |> Map.put("runId", "run-293-ab")

    middle =
      change(agent_id, Ecto.UUID.generate(), "write_file", "agent", @epoch_ms + 30)
      |> Map.put("runId", "run-293-a")

    newest =
      change(agent_id, Ecto.UUID.generate(), "archive", "agent", @epoch_ms + 40)
      |> Map.put("runId", "run-293-a")

    for change <- [first, other_run, middle, newest] do
      assert Changes.append(change, deadline()) == {:ok, change}
    end

    assert Changes.list(agent_id, [before_ms: @epoch_ms + 40], deadline()) ==
             {:ok, [middle, other_run, first]}

    assert Changes.list(agent_id, [run_id: "run-293-a"], deadline()) ==
             {:ok, [newest, middle, first]}

    assert Changes.list(
             agent_id,
             [before_ms: @epoch_ms + 40, run_id: "run-293-a", limit: 1],
             deadline()
           ) == {:ok, [middle]}
  end

  test "the default fifty-row page and a positive fractional limit select ordinary records", %{
    agent_id: agent_id
  } do
    by_number =
      Map.new(1..53, fn number ->
        change =
          change(agent_id, Ecto.UUID.generate(), "patch", "agent", @epoch_ms + number)
          |> Map.put("summary", "Recorded ordinary step #{number} 雪 😀")

        assert Changes.append(change, deadline()) == {:ok, change}
        {number, change}
      end)

    expected_default = for number <- 53..4//-1, do: Map.fetch!(by_number, number)
    assert Changes.list(agent_id, [], deadline()) == {:ok, expected_default}

    assert Changes.list(agent_id, [limit: 2.9], deadline()) ==
             {:ok, [Map.fetch!(by_number, 53), Map.fetch!(by_number, 52)]}

    assert Changes.list(agent_id, [before_ms: @epoch_ms + 4, limit: 3], deadline()) ==
             {:ok, [Map.fetch!(by_number, 3), Map.fetch!(by_number, 2), Map.fetch!(by_number, 1)]}
  end

  test "fresh normally completed caller processes read persisted changes and later appends", %{
    agent_id: agent_id
  } do
    first = change(agent_id, Ecto.UUID.generate(), "create", "agent", @epoch_ms + 1)
    assert in_fresh_process(fn -> Changes.append(first, deadline()) end) == {:ok, first}

    assert Changes.list(agent_id, [], deadline()) == {:ok, [first]}

    second = change(agent_id, Ecto.UUID.generate(), "patch", "user", @epoch_ms + 2)
    assert Changes.append(second, deadline()) == {:ok, second}

    assert in_fresh_process(fn -> Changes.list(agent_id, [], deadline()) end) ==
             {:ok, [second, first]}
  end

  defp change(agent_id, id, action, actor, created_at_ms) do
    %{
      "id" => id,
      "agentId" => agent_id,
      "skillName" => "release-guide",
      "action" => action,
      "actor" => actor,
      "summary" => "Recorded #{action}: café 雪 😀",
      "createdAtMs" => created_at_ms
    }
  end

  defp agent_namespace do
    id = Ecto.UUID.generate()

    on_exit(fn ->
      assert {:ok, %{succeeded: true}} =
               Concord.Turso.replace_prefix("coord/skill_workshop/agents/#{id}/", [],
                 timeout: 5_000
               )
    end)

    id
  end

  defp in_fresh_process(operation) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          {:execute, ^token} -> send(parent, {token, operation.()})
        after
          5_000 -> raise "ordinary test caller was not started"
        end
      end)

    send(pid, {:execute, token})
    assert_receive {^token, result}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    result
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
