defmodule Synapsis.Memory.StandingIntents.FunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Memory.StandingIntent.Store
  alias Synapsis.Memory.StandingIntents
  alias Synapsis.Memory.Writer

  @now 1_800_000_000_000
  @first "00000000-0000-4000-8000-000000000001"
  @second "00000000-0000-4000-8000-000000000002"
  @third "00000000-0000-4000-8000-000000000003"
  @last "ffffffff-ffff-4fff-bfff-ffffffffffff"

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{agent: Ecto.UUID.generate()}
  end

  test "fresh reads avoid writes and default create persists the complete public and raw value",
       %{
         agent: agent
       } do
    assert StandingIntents.list(agent, [], execution()) ==
             {:ok, %{value: [], next_due_at: :infinity}}

    assert StandingIntents.sweep(agent, execution()) ==
             {:ok, %{value: nil, next_due_at: :infinity}}

    assert {:ok, snapshot} = Store.snapshot(agent, deadline())
    assert Store.generation(snapshot) == 0
    assert Store.list_page(snapshot, [], deadline()) == {:ok, %{rows: [], next_cursor: nil}}

    assert {:ok, %{value: value, next_due_at: nil}} =
             StandingIntents.create(agent, prepared(), execution())

    id = value["id"]
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert value == public_row(id, @now)

    assert {:ok, snapshot} = Store.snapshot(agent, deadline())
    assert Store.generation(snapshot) == 1
    assert Store.get(snapshot, id, deadline()) == {:ok, raw_row(id, @now)}

    assert StandingIntents.list(agent, [], execution()) ==
             {:ok, %{value: [public_row(id, @now)], next_due_at: 1_807_776_000_000}}

    assert {:ok, after_list} = Store.snapshot(agent, deadline())
    assert Store.generation(after_list) == 1
  end

  test "real Data commit admission runs in its caller before the acknowledged generation", %{
    agent: agent
  } do
    assert {:ok, snapshot} = Store.snapshot(agent, deadline())
    assert Store.generation(snapshot) == 0
    row = raw_row(@first, @now)
    caller = self()

    before_commit = fn ->
      assert {:ok, observed} = Store.snapshot(agent, deadline())
      send(caller, {:commit_admission, self(), Store.generation(observed)})
      :ok
    end

    assert Store.commit(snapshot, [row], deadline(), before_commit: before_commit) ==
             {:ok, %{generation: 1}}

    assert_receive {:commit_admission, ^caller, 0}
    assert {:ok, current} = Store.snapshot(agent, deadline())
    assert Store.generation(current) == 1
    assert Store.get(current, @first, deadline()) == {:ok, row}
    assert Store.list_page(current, [], deadline()) == {:ok, %{rows: [row], next_cursor: nil}}
  end

  test "custom create retains scope custody and provenance without maintaining existing rows", %{
    agent: agent
  } do
    overdue = raw_row(@first, @now - 1_000, %{"expiresAt" => @now - 1})
    seed(agent, [overdue])

    params = %{
      "description" => "Review custom café 雪 😀.",
      "triggerKeywords" => ["release notes", "café 雪"],
      "creatorSender" => "\uFEFF Álice 雪 \u3000",
      "channelScope" => ~s(["v1","conversation","telegram","Account-雪","Room:CAFÉ 雪 😀"]),
      "senderScope" => ~s(["v1","telegram","Account-雪","ÁLICE:雪 😀"]),
      "expiresAt" => 1_800_086_400_000,
      "maxFires" => 2,
      "cooldownSeconds" => 60,
      "sourceSessionId" => "  provenance:雪/300  "
    }

    assert {:ok, %{value: value, next_due_at: nil}} =
             StandingIntents.create(agent, params, execution())

    id = value["id"]

    assert value == %{
             "id" => id,
             "description" => "Review custom café 雪 😀.",
             "triggerKeywords" => ["release notes", "café 雪"],
             "triggerEmbedding" => nil,
             "scope" => "conversation",
             "channelScope" => "Room:CAFÉ 雪 😀",
             "senderScope" => "ÁLICE:雪 😀",
             "creatorSender" => "Álice 雪",
             "status" => "armed",
             "expiresAt" => 1_800_086_400_000,
             "maxFires" => 2,
             "fireCount" => 0,
             "cooldownSeconds" => 60,
             "lastFiredAt" => nil,
             "createdAt" => @now,
             "sourceSessionId" => "  provenance:雪/300  "
           }

    assert {:ok, snapshot} = Store.snapshot(agent, deadline())
    assert Store.generation(snapshot) == 2
    assert Store.get(snapshot, @first, deadline()) == {:ok, overdue}

    assert Store.get(snapshot, id, deadline()) ==
             {:ok,
              %{
                "id" => id,
                "description" => "Review custom café 雪 😀.",
                "triggerKeywords" => ~s(["release notes","café 雪"]),
                "triggerEmbedding" => nil,
                "channelScope" =>
                  ~s(["v1","conversation","telegram","Account-雪","Room:CAFÉ 雪 😀"]),
                "senderScope" => ~s(["v1","telegram","Account-雪","ÁLICE:雪 😀"]),
                "creatorSender" => "Álice 雪",
                "status" => "armed",
                "expiresAt" => 1_800_086_400_000,
                "maxFires" => 2,
                "fireCount" => 0,
                "cooldownSeconds" => 60,
                "lastFiredAt" => nil,
                "createdAt" => @now,
                "sourceSessionId" => "  provenance:雪/300  "
              }}
  end

  test "ordinary listing orders unsorted rows by creation time then canonical UUID", %{
    agent: agent
  } do
    seed(agent, [
      raw_row(@first, @now + 300),
      raw_row(@last, @now + 200),
      raw_row(@second, @now + 100),
      raw_row(@third, @now + 200)
    ])

    assert StandingIntents.list(agent, [], execution()) ==
             {:ok,
              %{
                value: [
                  public_row(@second, @now + 100),
                  public_row(@third, @now + 200),
                  public_row(@last, @now + 200),
                  public_row(@first, @now + 300)
                ],
                next_due_at: 1_807_776_000_000
              }}

    assert {:ok, snapshot} = Store.snapshot(agent, deadline())
    assert Store.generation(snapshot) == 1
  end

  test "filtered list maintains all rows before filtering and retains encoded raw values", %{
    agent: agent
  } do
    scoped = %{
      "channelScope" => ~s(["v1","conversation","telegram","Account-雪","Room:CAFÉ 雪 😀"]),
      "senderScope" => ~s(["v1","telegram","Account-雪","ÁLICE:雪 😀"]),
      "status" => "fired",
      "fireCount" => 1,
      "cooldownSeconds" => 60,
      "lastFiredAt" => @now - 120_000,
      "expiresAt" => @now + 600_000
    }

    rearming = raw_row(@first, @now - 400, scoped)
    expiring = raw_row(@second, @now - 300, %{"expiresAt" => @now})

    cooling =
      raw_row(@third, @now - 200, %{
        "status" => "fired",
        "fireCount" => 1,
        "cooldownSeconds" => 60,
        "lastFiredAt" => @now - 30_000,
        "expiresAt" => @now + 900_000
      })

    done =
      raw_row(@last, @now - 100, %{
        "status" => "done",
        "fireCount" => 3,
        "lastFiredAt" => @now - 90_000,
        "expiresAt" => @now - 1
      })

    historical = seed(agent, [done, cooling, expiring, rearming])

    assert StandingIntents.list(agent, [status: "armed"], execution()) ==
             {:ok,
              %{
                value: [
                  public_row(@first, @now - 400, %{
                    "scope" => "conversation",
                    "channelScope" => "Room:CAFÉ 雪 😀",
                    "senderScope" => "ÁLICE:雪 😀",
                    "fireCount" => 1,
                    "cooldownSeconds" => 60,
                    "lastFiredAt" => @now - 120_000,
                    "expiresAt" => @now + 600_000
                  })
                ],
                next_due_at: 1_800_000_030_000
              }}

    assert {:ok, current} = Store.snapshot(agent, deadline())
    assert Store.generation(current) == 2
    assert Store.get(current, @first, deadline()) == {:ok, %{rearming | "status" => "armed"}}
    assert Store.get(current, @second, deadline()) == {:ok, %{expiring | "status" => "expired"}}
    assert Store.get(current, @third, deadline()) == {:ok, cooling}
    assert Store.get(current, @last, deadline()) == {:ok, done}
    assert Store.get(historical, @first, deadline()) == {:ok, rearming}
    assert Store.get(historical, @second, deadline()) == {:ok, expiring}

    assert {:ok, %{value: [value], next_due_at: 1_800_000_030_000}} =
             StandingIntents.list(agent, [status: "done"], execution())

    assert value ==
             public_row(@last, @now - 100, %{
               "status" => "done",
               "fireCount" => 3,
               "lastFiredAt" => @now - 90_000,
               "expiresAt" => @now - 1
             })

    assert {:ok, after_noop} = Store.snapshot(agent, deadline())
    assert Store.generation(after_noop) == 2
  end

  test "sweep commits ordinary lifecycle changes once and preserves terminal history", %{
    agent: agent
  } do
    pending = raw_row(@first, @now - 300, %{"status" => "pending", "expiresAt" => @now})

    fired =
      raw_row(@second, @now - 200, %{
        "status" => "fired",
        "fireCount" => 1,
        "cooldownSeconds" => 60,
        "lastFiredAt" => @now - 120_000,
        "expiresAt" => @now + 600_000
      })

    terminal = raw_row(@third, @now - 100, %{"status" => "expired", "expiresAt" => @now - 1})
    historical = seed(agent, [terminal, fired, pending])

    assert StandingIntents.sweep(agent, execution()) ==
             {:ok, %{value: nil, next_due_at: 1_800_000_600_000}}

    assert {:ok, current} = Store.snapshot(agent, deadline())
    assert Store.generation(current) == 2

    assert Store.list_page(current, [], deadline()) ==
             {:ok,
              %{
                rows: [
                  %{pending | "status" => "expired"},
                  %{fired | "status" => "armed"},
                  terminal
                ],
                next_cursor: nil
              }}

    assert Store.get(historical, @first, deadline()) == {:ok, pending}
    assert Store.get(historical, @second, deadline()) == {:ok, fired}

    assert StandingIntents.sweep(agent, execution()) ==
             {:ok, %{value: nil, next_due_at: 1_800_000_600_000}}

    assert {:ok, after_noop} = Store.snapshot(agent, deadline())
    assert Store.generation(after_noop) == 2
  end

  test "serial commands acknowledge after actual Writer task completion and normal DOWN", %{
    agent: agent
  } do
    writer = Process.whereis(Writer)
    assert is_pid(writer)
    assert {:flags, []} = :erlang.trace_info(writer, :flags)
    assert :erlang.trace(writer, true, [:receive, :send]) == 1

    on_exit(fn ->
      if Process.alive?(writer), do: :erlang.trace(writer, false, [:receive, :send])
    end)

    observer = self()

    observed_execution = %{
      execution()
      | assert_live: fn ->
          if self() != observer and self() != writer,
            do: send(observer, {:intent_worker, self()})

          :ok
        end
    }

    assert {:ok, %{value: value, next_due_at: nil}} =
             create_reply = StandingIntents.create(agent, prepared(), observed_execution)

    assert_receive {:intent_worker, create_worker}
    assert_normal_down_before_reply(writer, create_worker, create_reply)

    assert {:ok, %{value: [^value], next_due_at: 1_807_776_000_000}} =
             list_reply = StandingIntents.list(agent, [], observed_execution)

    assert_receive {:intent_worker, list_worker} when list_worker != create_worker
    assert_normal_down_before_reply(writer, list_worker, list_reply)

    assert {:ok, snapshot} = Store.snapshot(agent, deadline())
    assert Store.generation(snapshot) == 1
  end

  test "normally completed fresh callers retain one Agent inventory and isolate another Agent", %{
    agent: agent
  } do
    assert StandingIntents.list(agent, [], execution()) ==
             {:ok, %{value: [], next_due_at: :infinity}}

    assert {:ok, %{value: first, next_due_at: nil}} =
             from_fresh_caller(fn -> StandingIntents.create(agent, prepared(), execution()) end)

    assert {:ok, %{value: [^first], next_due_at: 1_807_776_000_000}} =
             from_fresh_caller(fn -> StandingIntents.list(agent, [], execution()) end)

    other_agent = Ecto.UUID.generate()

    assert StandingIntents.list(other_agent, [], execution()) ==
             {:ok, %{value: [], next_due_at: :infinity}}

    assert {:ok, %{value: other, next_due_at: nil}} =
             from_fresh_caller(fn ->
               StandingIntents.create(other_agent, prepared(), execution(@now + 1_000))
             end)

    assert other == public_row(other["id"], @now + 1_000, %{"expiresAt" => 1_807_776_001_000})

    assert StandingIntents.list(agent, [], execution()) ==
             {:ok, %{value: [first], next_due_at: 1_807_776_000_000}}

    assert StandingIntents.list(other_agent, [], execution(@now + 1_000)) ==
             {:ok, %{value: [other], next_due_at: 1_807_776_001_000}}

    assert {:ok, original_snapshot} = Store.snapshot(agent, deadline())
    assert {:ok, other_snapshot} = Store.snapshot(other_agent, deadline())
    assert Store.generation(original_snapshot) == 1
    assert Store.generation(other_snapshot) == 1
  end

  defp prepared do
    %{
      "description" => "  Review café 雪 😀.  ",
      "triggerKeywords" => ["Release Notes", "café 雪"],
      "creatorSender" => "\uFEFF Álice 雪 \u3000"
    }
  end

  defp raw_row(id, created_at, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "description" => "  Review café 雪 😀.  ",
        "triggerKeywords" => ~s(["Release Notes","café 雪"]),
        "triggerEmbedding" => nil,
        "channelScope" => nil,
        "senderScope" => nil,
        "creatorSender" => "Álice 雪",
        "status" => "armed",
        "expiresAt" => 1_807_776_000_000,
        "maxFires" => 3,
        "fireCount" => 0,
        "cooldownSeconds" => 86_400,
        "lastFiredAt" => nil,
        "createdAt" => created_at,
        "sourceSessionId" => nil
      },
      overrides
    )
  end

  defp public_row(id, created_at, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "description" => "  Review café 雪 😀.  ",
        "triggerKeywords" => ["Release Notes", "café 雪"],
        "triggerEmbedding" => nil,
        "scope" => "anywhere",
        "channelScope" => nil,
        "senderScope" => nil,
        "creatorSender" => "Álice 雪",
        "status" => "armed",
        "expiresAt" => 1_807_776_000_000,
        "maxFires" => 3,
        "fireCount" => 0,
        "cooldownSeconds" => 86_400,
        "lastFiredAt" => nil,
        "createdAt" => created_at,
        "sourceSessionId" => nil
      },
      overrides
    )
  end

  defp seed(agent, rows) do
    assert {:ok, empty} = Store.snapshot(agent, deadline())
    assert Store.commit(empty, rows, deadline()) == {:ok, %{generation: 1}}
    assert {:ok, snapshot} = Store.snapshot(agent, deadline())
    snapshot
  end

  defp from_fresh_caller(operation) do
    parent = self()
    tag = make_ref()

    {caller, monitor} =
      spawn_monitor(fn -> send(parent, {tag, self(), operation.()}) end)

    assert_receive {^tag, ^caller, result}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5_000
    result
  end

  defp assert_normal_down_before_reply(writer, worker, reply) do
    delivered = :erlang.trace_delivered(writer)
    assert_receive {:trace_delivered, ^writer, ^delivered}, 5_000
    events = trace_events(writer, [])

    down_index =
      Enum.find_index(events, fn event ->
        match?({:trace, ^writer, :receive, {:DOWN, _, :process, ^worker, :normal}}, event)
      end)

    reply_index =
      Enum.find_index(events, fn event ->
        match?({:trace, ^writer, :send, {_, ^reply}, _}, event)
      end)

    assert is_integer(down_index)
    assert is_integer(reply_index)
    assert down_index < reply_index
  end

  defp trace_events(writer, events) do
    receive do
      {:trace, ^writer, :receive, _} = event -> trace_events(writer, [event | events])
      {:trace, ^writer, :send, _, _} = event -> trace_events(writer, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp execution(now \\ @now) do
    %{deadline: deadline(), assert_live: fn -> :ok end, now_ms: now}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
