defmodule Synapsis.Memory.StandingIntent.StoreFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Memory.StandingIntent.Store

  @epoch_ms 1_800_000_000_000
  @first_id "00000000-0000-4000-8000-000000000001"
  @second_id "00000000-0000-4000-8000-000000000002"
  @third_id "00000000-0000-4000-8000-000000000003"
  @last_id "ffffffff-ffff-4fff-bfff-ffffffffffff"

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{agent_id: Ecto.UUID.generate()}
  end

  test "a fresh Agent snapshot has generation zero and an empty completed page", %{
    agent_id: agent_id
  } do
    assert {:ok, snapshot} = Store.snapshot(agent_id, deadline())
    assert Store.generation(snapshot) == 0

    assert Store.list_page(snapshot, [], deadline()) ==
             {:ok, %{rows: [], next_cursor: nil}}
  end

  test "an acknowledged commit retains complete source rows with Unicode nulls and provenance", %{
    agent_id: agent_id
  } do
    first = row(@first_id, @epoch_ms)

    second =
      row(@second_id, @epoch_ms + 1_000, %{
        "description" => "Review the release notes: café 雪 😀.",
        "triggerKeywords" => ["release check", "café 雪"],
        "scope" => "conversation",
        "channelScope" => "conversation-298-雪",
        "senderScope" => nil,
        "sourceSessionId" => nil,
        "expiresAt" => 1_800_259_200_000,
        "maxFires" => 2,
        "cooldownSeconds" => 60
      })

    assert {:ok, original} = Store.snapshot(agent_id, deadline())
    assert Store.commit(original, [second, first], deadline()) == {:ok, %{generation: 1}}
    assert Store.generation(original) == 0

    assert {:ok, current} = Store.snapshot(agent_id, deadline())
    assert Store.generation(current) == 1
    assert Store.get(current, @first_id, deadline()) == {:ok, first}
    assert Store.get(current, @second_id, deadline()) == {:ok, second}

    assert Store.list_page(current, [], deadline()) ==
             {:ok, %{rows: [first, second], next_cursor: nil}}
  end

  test "ordinary continuation pages order unsorted rows by creation time then canonical UUID", %{
    agent_id: agent_id
  } do
    earliest = row(@second_id, @epoch_ms + 100)
    first_tie = row(@third_id, @epoch_ms + 200)
    last_tie = row(@last_id, @epoch_ms + 200)
    latest = row(@first_id, @epoch_ms + 300)

    assert {:ok, empty} = Store.snapshot(agent_id, deadline())

    assert Store.commit(empty, [latest, last_tie, earliest, first_tie], deadline()) ==
             {:ok, %{generation: 1}}

    assert {:ok, snapshot} = Store.snapshot(agent_id, deadline())

    assert {:ok, %{rows: [^earliest, ^first_tie], next_cursor: cursor}} =
             Store.list_page(snapshot, [limit: 2], deadline())

    refute is_nil(cursor)

    assert Store.list_page(snapshot, [limit: 2, after: cursor], deadline()) ==
             {:ok, %{rows: [last_tie, latest], next_cursor: nil}}

    assert Store.list_page(snapshot, [], deadline()) ==
             {:ok, %{rows: [earliest, first_tie, last_tie, latest], next_cursor: nil}}
  end

  test "atomic replacements and an append preserve historical gets and continuation pages", %{
    agent_id: agent_id
  } do
    first = row(@first_id, @epoch_ms + 100)
    second = row(@second_id, @epoch_ms + 200)
    last = row(@last_id, @epoch_ms + 400)

    assert {:ok, empty} = Store.snapshot(agent_id, deadline())
    assert Store.commit(empty, [last, second, first], deadline()) == {:ok, %{generation: 1}}
    assert {:ok, historical} = Store.snapshot(agent_id, deadline())

    assert {:ok, %{rows: [^first], next_cursor: historical_cursor}} =
             Store.list_page(historical, [limit: 1], deadline())

    refute is_nil(historical_cursor)

    first_replacement =
      Map.merge(first, %{
        "description" => "Deployment checklist reviewed: 雪 😀.",
        "status" => "fired",
        "fireCount" => 1,
        "lastFiredAt" => @epoch_ms + 2_000
      })

    second_replacement =
      Map.merge(second, %{
        "description" => "Release notes reviewed: café.",
        "status" => "fired",
        "fireCount" => 1,
        "lastFiredAt" => @epoch_ms + 2_000
      })

    appended = row(@third_id, @epoch_ms + 300)

    assert Store.commit(
             historical,
             [second_replacement, appended, first_replacement],
             deadline()
           ) == {:ok, %{generation: 2}}

    assert Store.generation(historical) == 1
    assert Store.get(historical, @first_id, deadline()) == {:ok, first}
    assert Store.get(historical, @second_id, deadline()) == {:ok, second}

    assert Store.list_page(historical, [limit: 2, after: historical_cursor], deadline()) ==
             {:ok, %{rows: [second, last], next_cursor: nil}}

    assert Store.list_page(historical, [], deadline()) ==
             {:ok, %{rows: [first, second, last], next_cursor: nil}}

    assert {:ok, current} = Store.snapshot(agent_id, deadline())
    assert Store.generation(current) == 2
    assert Store.get(current, @first_id, deadline()) == {:ok, first_replacement}
    assert Store.get(current, @second_id, deadline()) == {:ok, second_replacement}
    assert Store.get(current, @third_id, deadline()) == {:ok, appended}

    assert Store.list_page(current, [], deadline()) ==
             {:ok,
              %{rows: [first_replacement, second_replacement, appended, last], next_cursor: nil}}
  end

  test "normally finished callers retain persistent rows in independent Agent namespaces and directory",
       %{
         agent_id: agent_id
       } do
    other_agent_id = Ecto.UUID.generate()
    first = row(@first_id, @epoch_ms)

    other =
      row(@first_id, @epoch_ms, %{
        "description" => "Independent Agent reminder: 雪 😀.",
        "sourceSessionId" => "other-source-session-298"
      })

    assert {:ok, initial} = Store.snapshot(agent_id, deadline())
    assert Store.generation(initial) == 0

    assert in_fresh_process(fn ->
             assert {:ok, snapshot} = Store.snapshot(agent_id, deadline())
             Store.commit(snapshot, [first], deadline())
           end) == {:ok, %{generation: 1}}

    assert {:ok, other_snapshot} = Store.snapshot(other_agent_id, deadline())
    assert Store.generation(other_snapshot) == 0
    assert Store.commit(other_snapshot, [other], deadline()) == {:ok, %{generation: 1}}

    assert in_fresh_process(fn ->
             assert {:ok, snapshot} = Store.snapshot(agent_id, deadline())

             {
               Store.generation(snapshot),
               Store.get(snapshot, @first_id, deadline()),
               Store.list_page(snapshot, [], deadline())
             }
           end) == {1, {:ok, first}, {:ok, %{rows: [first], next_cursor: nil}}}

    assert {:ok, current_other} = Store.snapshot(other_agent_id, deadline())
    assert Store.generation(current_other) == 1
    assert Store.get(current_other, @first_id, deadline()) == {:ok, other}

    assert Store.list_page(current_other, [], deadline()) ==
             {:ok, %{rows: [other], next_cursor: nil}}

    agent_ids = in_fresh_process(fn -> directory_agents([]) end)
    assert agent_id in agent_ids
    assert other_agent_id in agent_ids
  end

  # Source-shaped payloads are independent literals, not Store output or storage envelopes.
  defp row(id, created_at, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "description" => "Review the deployment checklist: café 雪 😀.",
        "triggerKeywords" => ["deploy", "release check", "café 雪"],
        "triggerEmbedding" => nil,
        "scope" => "channel",
        "channelScope" => "webchat",
        "senderScope" => "synapsis:operator",
        "creatorSender" => "synapsis:operator",
        "status" => "armed",
        "expiresAt" => 1_807_776_000_000,
        "maxFires" => 3,
        "fireCount" => 0,
        "cooldownSeconds" => 86_400,
        "lastFiredAt" => nil,
        "createdAt" => created_at,
        "sourceSessionId" => "source-session-298"
      },
      overrides
    )
  end

  defp directory_agents(opts) do
    assert {:ok, %{agent_ids: agent_ids, next_cursor: cursor}} =
             Store.agents_page([limit: 2] ++ opts, deadline())

    case cursor do
      nil -> agent_ids
      next -> agent_ids ++ directory_agents(after: next)
    end
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
    assert_receive {^token, result}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    result
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
