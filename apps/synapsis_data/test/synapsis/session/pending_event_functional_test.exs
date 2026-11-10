defmodule Synapsis.Session.PendingEventFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Session.{PendingInputStore, Store}

  setup do
    assert :ok = Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)

    %{
      session_id: session_id,
      owner_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      source_session_id: Ecto.UUID.generate(),
      source_agent_id: Ecto.UUID.generate()
    }
  end

  test "pending snapshots can be created and replaced with an acknowledged exact snapshot", ctx do
    assert {:ok, :absent} = Store.read_pending_inputs(ctx.session_id)
    first = [%{"id" => Ecto.UUID.generate(), "future" => %{"keep" => [1, 1.0]}}]
    assert :ok = Store.compare_put_pending_inputs(ctx.session_id, :absent, first)
    assert {:ok, {:present, ^first, first_revision}} = Store.read_pending_inputs(ctx.session_id)
    assert is_integer(first_revision) and first_revision > 0

    numeric_update = [put_in(hd(first), ["future", "keep"], [1.0, 1])]
    assert :ok = Store.put_value(ctx.session_id, "pending_inputs", numeric_update)

    assert {:ok, {:present, reloaded, numeric_revision} = fresh_snapshot} =
             Store.read_pending_inputs(ctx.session_id)

    assert reloaded === numeric_update
    assert is_integer(numeric_revision) and numeric_revision > first_revision
    second = reloaded ++ [%{id: Ecto.UUID.generate(), future: "also retained"}]
    assert :ok = Store.compare_put_pending_inputs(ctx.session_id, fresh_snapshot, second)
    assert {:ok, {:present, ^second, second_revision}} = Store.read_pending_inputs(ctx.session_id)
    assert is_integer(second_revision) and second_revision > numeric_revision
  end

  test "identical wake calls retain distinct ordered occurrences and captured provenance", ctx do
    attrs = event_attrs(ctx, "same event")
    assert {:ok, first} = PendingInputStore.append_event(ctx.session_id, attrs)
    assert {:ok, second} = PendingInputStore.append_event(ctx.session_id, attrs)

    assert {:ok, first.id} == Ecto.UUID.cast(first.id)
    assert {:ok, second.id} == Ecto.UUID.cast(second.id)
    assert first.id != second.id
    assert first.inserted_at < second.inserted_at
    assert {:ok, [^first, ^second]} = PendingInputStore.list_result(ctx.session_id)
    assert PendingInputStore.list(ctx.session_id) == [first, second]
    assert first.kind == "system_event"
    assert first.status == "queued"
    assert first.image_parts == []
    assert first.input_provenance == attrs.input_provenance

    assert first.event == %{
             "owner_id" => ctx.owner_id,
             "target_agent_id" => ctx.agent_id,
             "mode" => "next-heartbeat",
             "phase" => "staged"
           }
  end

  test "event text follows ECMAScript outer whitespace semantics while preserving body text",
       ctx do
    whitespace =
      <<0x0009::utf8, 0x000A::utf8, 0x000B::utf8, 0x000C::utf8, 0x000D::utf8, 0x0020::utf8,
        0x00A0::utf8, 0x1680::utf8, 0x2000::utf8, 0x2001::utf8, 0x2002::utf8, 0x2003::utf8,
        0x2004::utf8, 0x2005::utf8, 0x2006::utf8, 0x2007::utf8, 0x2008::utf8, 0x2009::utf8,
        0x200A::utf8, 0x2028::utf8, 0x2029::utf8, 0x202F::utf8, 0x205F::utf8, 0x3000::utf8,
        0xFEFF::utf8>>

    for text <- ["事件\n  body", "\u0085event\u0085"] do
      assert {:ok, event} =
               PendingInputStore.append_event(
                 ctx.session_id,
                 event_attrs(ctx, whitespace <> text <> whitespace)
               )

      assert event.content == text
    end
  end

  test "ordinary prompts and owned events take exclusive turns in committed order", ctx do
    assert {:ok, first} = PendingInputStore.append_prompt(ctx.session_id, "first prompt", [])
    assert {:ok, steer} = PendingInputStore.append_steer(ctx.session_id, "current turn")

    assert {:ok, foreign} =
             PendingInputStore.append_event(
               ctx.session_id,
               %{event_attrs(ctx, "other owner") | owner_id: Ecto.UUID.generate()}
             )

    assert {:ok, event} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx))
    assert {:ok, last} = PendingInputStore.append_prompt(ctx.session_id, "last prompt", [])

    for input <- [first, event, last] do
      assert {:ok, ^input} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)
    end

    assert :empty = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)
    assert {:ok, rows} = PendingInputStore.list_result(ctx.session_id)
    assert Enum.find(rows, &(&1.id == foreign.id)) == foreign
    assert Enum.find(rows, &(&1.id == steer.id)) == steer

    assert Enum.map(Enum.filter(rows, &(&1.id in [first.id, event.id, last.id])), & &1.status) ==
             ["inflight", "inflight", "inflight"]
  end

  test "actual concurrent prompt steer and event appends retain every successful input", ctx do
    caller = self()
    batch = make_ref()

    tasks =
      for append <- [
            fn -> PendingInputStore.append_prompt(ctx.session_id, "prompt", []) end,
            fn -> PendingInputStore.append_steer(ctx.session_id, "steer") end,
            fn -> PendingInputStore.append_event(ctx.session_id, event_attrs(ctx, "event")) end
          ] do
        Task.async(fn ->
          send(caller, {:ready, batch, self()})

          receive do
            {:append, ^batch} -> append.()
          end
        end)
      end

    for task <- tasks, do: assert_receive({:ready, ^batch, pid} when pid == task.pid)
    for task <- tasks, do: send(task.pid, {:append, batch})

    inputs =
      Enum.map(tasks, fn task ->
        assert {:ok, input} = Task.await(task, 10_000)
        input
      end)

    assert {:ok, reloaded} = PendingInputStore.list_result(ctx.session_id)
    assert MapSet.new(reloaded, & &1.id) == MapSet.new(inputs, & &1.id)
    assert Enum.sort(Enum.map(reloaded, & &1.content)) == ["event", "prompt", "steer"]
    assert length(Enum.uniq_by(reloaded, & &1.inserted_at)) == 3
  end

  test "adopting one exact occurrence is idempotent and preserves its duplicate sibling", ctx do
    assert {:ok, first} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx))
    assert {:ok, sibling} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx))
    run_id = Ecto.UUID.generate()
    assert {:ok, ^first} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)
    assert :ok = PendingInputStore.start_event(ctx.session_id, first.id, ctx.owner_id, run_id)
    assert :ok = PendingInputStore.start_event(ctx.session_id, first.id, ctx.owner_id, run_id)

    assert {:ok, [started, ^sibling]} = PendingInputStore.list_result(ctx.session_id)
    assert started.id == first.id
    assert started.status == "consumed"
    assert started.event["phase"] == "started"
    assert started.event["run_id"] == run_id
    assert {:ok, ^sibling} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)
  end

  test "correlated terminal event history survives durable reload without altering later input",
       ctx do
    assert {:ok, event} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx))
    assert {:ok, prompt} = PendingInputStore.append_prompt(ctx.session_id, "later", [])
    run_id = Ecto.UUID.generate()
    assert {:ok, ^event} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)
    assert :ok = PendingInputStore.start_event(ctx.session_id, event.id, ctx.owner_id, run_id)

    assert :ok =
             PendingInputStore.finish_event(ctx.session_id, event.id, ctx.owner_id, :completed)

    assert {:ok, {:present, raw, revision}} = Store.read_pending_inputs(ctx.session_id)
    assert is_integer(revision) and revision > 0
    assert length(raw) == 2
    assert {:ok, [completed, ^prompt]} = PendingInputStore.list_result(ctx.session_id)
    assert completed.id == event.id
    assert completed.status == "consumed"
    assert completed.event["phase"] == "completed"
    assert completed.event["run_id"] == run_id
    assert completed.input_provenance == event.input_provenance
  end

  test "owner handoff preserves completed history and recovers human input separately", ctx do
    assert {:ok, historical} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx))
    assert {:ok, ^historical} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)

    assert :ok =
             PendingInputStore.start_event(
               ctx.session_id,
               historical.id,
               ctx.owner_id,
               Ecto.UUID.generate()
             )

    assert :ok =
             PendingInputStore.finish_event(
               ctx.session_id,
               historical.id,
               ctx.owner_id,
               :completed
             )

    assert {:ok, old_event} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx))
    assert {:ok, prompt} = PendingInputStore.append_prompt(ctx.session_id, "recover prompt", [])
    assert {:ok, ^prompt} = PendingInputStore.take_next_prompt(ctx.session_id)
    assert {:ok, steer} = PendingInputStore.append_steer(ctx.session_id, "recover steer")
    assert [^steer] = PendingInputStore.take_queued_steers(ctx.session_id)
    next_owner = Ecto.UUID.generate()

    assert {:ok, current} =
             PendingInputStore.append_event(
               ctx.session_id,
               %{event_attrs(ctx) | owner_id: next_owner}
             )

    assert {:ok, [completed | _]} = PendingInputStore.list_result(ctx.session_id)
    assert :ok = PendingInputStore.recover_for_owner(ctx.session_id, next_owner)

    assert {:ok, [^completed, lost, recovered_prompt, recovered_steer, ^current]} =
             PendingInputStore.list_result(ctx.session_id)

    assert lost.id == old_event.id
    assert lost.status == "owner_lost"
    assert lost.event["phase"] == "owner_lost"
    assert recovered_prompt.id == prompt.id
    assert recovered_prompt.status == "queued"
    assert recovered_steer.id == steer.id
    assert recovered_steer.status == "queued"
    assert {:ok, ^recovered_prompt} = PendingInputStore.take_next_turn(ctx.session_id, next_owner)
    assert {:ok, ^current} = PendingInputStore.take_next_turn(ctx.session_id, next_owner)
  end

  test "legacy inflight recovery retains typed event custody", ctx do
    assert {:ok, event} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx))
    assert {:ok, ^event} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)
    assert {:ok, prompt} = PendingInputStore.append_prompt(ctx.session_id, "human", [])
    assert {:ok, ^prompt} = PendingInputStore.take_next_prompt(ctx.session_id)
    assert :ok = PendingInputStore.recover_inflight(ctx.session_id)

    assert {:ok, [retained_event, recovered_prompt]} =
             PendingInputStore.list_result(ctx.session_id)

    assert retained_event.id == event.id
    assert retained_event.status == "inflight"
    assert retained_event.event == event.event
    assert recovered_prompt.id == prompt.id
    assert recovered_prompt.status == "queued"
  end

  test "twenty events and twenty five ordinary inputs have independent capacity", ctx do
    events =
      for n <- 1..20 do
        assert {:ok, event} =
                 PendingInputStore.append_event(ctx.session_id, event_attrs(ctx, "event #{n}"))

        event
      end

    for n <- 1..13 do
      assert {:ok, _} = PendingInputStore.append_prompt(ctx.session_id, "prompt #{n}", [])
    end

    for n <- 1..12 do
      assert {:ok, _} = PendingInputStore.append_steer(ctx.session_id, "steer #{n}")
    end

    assert {:ok, rows} = PendingInputStore.list_result(ctx.session_id)
    assert length(rows) == 45
    first = hd(events)
    assert {:ok, ^first} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)

    assert :ok =
             PendingInputStore.start_event(
               ctx.session_id,
               first.id,
               ctx.owner_id,
               Ecto.UUID.generate()
             )

    assert {:ok, _} = PendingInputStore.append_event(ctx.session_id, event_attrs(ctx, "event 21"))
    assert length(PendingInputStore.queued_prompts(ctx.session_id)) == 13
    assert length(PendingInputStore.queued_steers(ctx.session_id)) == 12
  end

  test "ordinary queue APIs retain image data return shapes and unknown stored fields", ctx do
    images = [%{"type" => "image", "media_type" => "image/png", "data" => "aW1hZ2U="}]
    assert {:ok, prompt} = PendingInputStore.append_prompt(ctx.session_id, "see image", images)
    assert {:ok, steer} = PendingInputStore.append_steer(ctx.session_id, "adjust")
    [raw_prompt, raw_steer] = Store.get_value(ctx.session_id, "pending_inputs")
    raw_prompt = Map.put(raw_prompt, "future_metadata", %{"keep" => [1, 1.0]})
    assert :ok = Store.put_value(ctx.session_id, "pending_inputs", [raw_prompt, raw_steer])
    assert {:ok, ^prompt} = PendingInputStore.take_next_prompt(ctx.session_id)
    assert [^steer] = PendingInputStore.take_queued_steers(ctx.session_id)
    assert :ok = PendingInputStore.mark_consumed(ctx.session_id, prompt.id)
    assert :ok = PendingInputStore.recover_inflight(ctx.session_id)
    assert :ok = PendingInputStore.cancel_steers(ctx.session_id)
    assert [] = PendingInputStore.take_queued_steers(ctx.session_id)
    assert :empty = PendingInputStore.take_next_prompt(ctx.session_id)

    assert [%{status: "consumed", image_parts: ^images}, %{status: "cancelled"}] =
             PendingInputStore.list(ctx.session_id)

    [persisted_prompt, _] = Store.get_value(ctx.session_id, "pending_inputs")
    assert persisted_prompt["future_metadata"] == %{"keep" => [1, 1.0]}
  end

  defp event_attrs(ctx, content \\ "wake event") do
    %{
      content: content,
      owner_id: ctx.owner_id,
      target_agent_id: ctx.agent_id,
      mode: "next-heartbeat",
      input_provenance: %{
        "kind" => "internal_system",
        "source_tool" => "cron",
        "source_session_id" => ctx.source_session_id,
        "source_agent_id" => ctx.source_agent_id
      }
    }
  end
end
