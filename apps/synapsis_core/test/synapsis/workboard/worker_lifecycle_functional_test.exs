defmodule Synapsis.Workboard.CoreWorkerLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Independent ordinary vectors from unchanged OpenClaw 488631c whole modules.
  # Source report: /tmp/synapsis-workboard386-source-ryui9pir/source-report.json.
  # This trusted internal execute/4 surface accepts domain ownerId/token inputs.
  # It is not the native/model factory, whose owner comes from trusted context
  # and whose returned card redacts the claim token. No product candidate read.
  # Notification highwater is the approved durable per-explicit-scope host
  # adaptation; source's counter is volatile per original Store instance.
  # No execution/attempt/session/run finishing or excluded cases are qualified.
  @creator %{
    "runId" => "fixture:386:create",
    "incarnation" => 61,
    "extra" => %{"json" => [nil, true, 1.5, "雪😀"]}
  }
  @writer %{
    "runId" => "fixture:386:worker",
    "incarnation" => 62,
    "toolCallId" => "fixture:386:ordinary-call",
    "extra" => %{"supplied" => [false, 2, %{"text" => "café 雪😀"}]}
  }
  @owner "fixture:386:ordinary-owner"

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:386:lifecycle/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "full ordinary claim heartbeat release claim complete persists exact records and worker context",
       %{context: context} do
    board(context, "alpha")

    initial =
      create(context, "alpha", "Rich lifecycle", "backlog", %{
        "notes" => "Ordinary body 雪😀.",
        "tenant" => "fixture-tenant",
        "idempotencyKey" => "rich-cycle",
        "skills" => ["inspect", "review"],
        "workspace" => %{"kind" => "dir", "path" => "/supplied/workspace"}
      })

    {claimed, token} = claim(context, initial, %{}, "running", "moved")
    first_started = claimed["startedAt"]
    plain = heartbeat(context, claimed, %{"token" => token}, nil)
    noted = heartbeat(context, plain, %{"note" => " \uFEFFProgress 雪😀\u00A0 "}, "Progress 雪😀")
    released = release(context, noted, %{"token" => token, "status" => "todo"}, "todo", "moved")
    assert released["startedAt"] == first_started
    {reclaimed, next_token} = claim(context, released, %{"ttlSeconds" => 95}, "running", "moved")
    assert reclaimed["startedAt"] == first_started
    assert next_token != token

    complete_args = %{
      "token" => next_token,
      "summary" => " \uFEFFCompleted 雪😀\u00A0 ",
      "proof" => %{
        "status" => "passed",
        "label" => " Checked 雪😀 ",
        "command" => " mix test scoped ",
        "url" => " https://example.test/proof ",
        "note" => " Supplied evidence "
      },
      "artifacts" => [
        %{
          "label" => " Report 雪😀 ",
          "path" => " result.txt ",
          "url" => " https://example.test/report ",
          "mimeType" => " text/plain "
        }
      ]
    }

    done = complete(context, reclaimed, complete_args, "Completed 雪😀")
    [proof] = done["metadata"]["proof"]
    [artifact] = done["metadata"]["artifacts"]
    notification = List.last(done["metadata"]["notifications"])

    assert proof == %{
             "id" => uuid(proof["id"]),
             "status" => "passed",
             "createdAt" => notification["createdAt"],
             "label" => "Checked 雪😀",
             "command" => "mix test scoped",
             "url" => "https://example.test/proof",
             "note" => "Supplied evidence"
           }

    assert artifact == %{
             "id" => uuid(artifact["id"]),
             "createdAt" => notification["createdAt"],
             "label" => "Report 雪😀",
             "path" => "result.txt",
             "url" => "https://example.test/report",
             "mimeType" => "text/plain"
           }

    assert proof["id"] != artifact["id"] and proof["id"] != notification["id"]

    assert Enum.map(done["events"], & &1["kind"]) ==
             ["created", "moved", "heartbeat", "heartbeat", "moved", "moved", "moved"]

    assert done["startedAt"] == first_started

    assert done["metadata"]["automation"] == %{
             "boardId" => "alpha",
             "tenant" => "fixture-tenant",
             "idempotencyKey" => "rich-cycle",
             "skills" => ["inspect", "review"],
             "workspace" => %{"kind" => "dir", "path" => "/supplied/workspace"},
             "summary" => "Completed 雪😀"
           }

    expected_context =
      "# Workboard card #{done["id"]}\nTitle: Rich lifecycle\nStatus: done\nPriority: normal\nBoard: alpha\nAgent: (default)" <>
        "\n\n## Notes\nOrdinary body 雪😀." <>
        "\n\n## Recent comments\n- Progress 雪😀\n- Completed 雪😀" <>
        "\n\n## Proof\n- passed: Checked 雪😀" <>
        "\n\n## Artifacts\n- Report 雪😀" <>
        "\n\n## Automation\nTenant: fixture-tenant\nBoard: alpha\nSkills: inspect, review\nWorkspace: dir /supplied/workspace\nSummary: Completed 雪😀"

    assert_read(context, done, expected_context)

    assert execute(context, "list", %{"boardId" => "alpha"}) ==
             {:ok,
              %{
                "cards" => [
                  %{
                    "id" => done["id"],
                    "title" => "Rich lifecycle",
                    "status" => "done",
                    "priority" => "normal",
                    "tenant" => "fixture-tenant",
                    "boardId" => "alpha",
                    "updatedAt" => done["updatedAt"]
                  }
                ]
              }}

    reader =
      Task.async(fn ->
        point = snapshot(context)
        {get_item(point, done["id"]), execute(context, "read", %{"id" => done["id"]})}
      end)

    assert {fresh, {:ok, %{"card" => ^done, "workerContext" => ^expected_context}}} =
             Task.await(reader, 5_000)

    assert fresh.record.payload == done and fresh.record.provenance == @creator
  end

  test "ordinary omitted status release and supplied token keep triage then allow second board claim",
       %{context: context} do
    board(context, "alpha")
    board(context, "beta")
    triage = create(context, "alpha", "Triage retained", "triage")
    supplied_token = Ecto.UUID.generate()

    {claimed, token} =
      claim(
        context,
        triage,
        %{
          "ownerId" => " \uFEFF" <> @owner <> "\u00A0 ",
          "token" => " " <> supplied_token <> " ",
          "ttlSeconds" => 120
        },
        "triage",
        "claimed"
      )

    assert token == supplied_token
    refute Map.has_key?(claimed, "startedAt")
    renewed = heartbeat(context, claimed, %{}, nil)
    released = release(context, renewed, %{}, "triage", "claimed")
    assert released["metadata"] == triage["metadata"]
    refute Map.has_key?(released, "startedAt")
    second = create(context, "beta", "Second after release", "ready")
    {second_claim, _} = claim(context, second, %{}, "running", "moved")
    done = complete(context, second_claim, %{}, nil)

    assert done["metadata"] == %{
             "automation" => %{"boardId" => "beta"},
             "notifications" => done["metadata"]["notifications"]
           }

    assert List.last(done["metadata"]["notifications"])["message"] == "Workboard card completed."
  end

  test "ordinary admitted initial statuses use exact source status and event defaults", %{
    context: context
  } do
    board(context, "alpha")

    for {status, next_status, event_kind} <- [
          {"backlog", "running", "moved"},
          {"todo", "running", "moved"},
          {"ready", "running", "moved"},
          {"review", "review", "claimed"},
          {"running", "running", "claimed"}
        ] do
      initial = create(context, "alpha", "Admitted " <> status, status)
      {claimed, _} = claim(context, initial, %{}, next_status, event_kind)
      done = complete(context, claimed, %{}, nil)

      assert done["metadata"] == %{
               "automation" => %{"boardId" => "alpha"},
               "notifications" => done["metadata"]["notifications"]
             }
    end
  end

  test "successful existing proof resolution preserves evidence identity time and fields", %{
    context: context
  } do
    board(context, "alpha")
    initial = create(context, "alpha", "Resolve proof", "todo")

    assert {:ok, %{"card" => proofed, "proofId" => proof_id}} =
             execute(writer(context), "proof", %{
               "id" => initial["id"],
               "status" => "unknown",
               "label" => "Build evidence",
               "command" => "mix compile",
               "note" => "Supplied pending proof"
             })

    [pending] = proofed["metadata"]["proof"]
    assert pending["id"] == proof_id
    {claimed, token} = claim(context, proofed, %{}, "running", "moved")

    done =
      complete(
        context,
        claimed,
        %{
          "token" => token,
          "proofId" => " " <> proof_id <> " ",
          "proof" => %{"status" => "passed"}
        },
        nil
      )

    assert done["metadata"]["proof"] == [Map.put(pending, "status", "passed")]
    assert length(done["events"]) == length(claimed["events"]) + 1

    second = create(context, "alpha", "Retain resolved proof", "todo")

    assert {:ok, %{"card" => already, "proofId" => resolved_id}} =
             execute(writer(context), "proof", %{
               "id" => second["id"],
               "status" => "passed",
               "label" => "Already passed"
             })

    {next_claim, _} = claim(context, already, %{}, "running", "moved")
    next_done = complete(context, next_claim, %{"proofId" => resolved_id}, nil)
    assert next_done["metadata"]["proof"] == already["metadata"]["proof"]
  end

  test "done dependencies persist their ready event before the ordinary claim event", %{
    context: context
  } do
    board(context, "alpha")
    parent = create(context, "alpha", "Already done parent", "done")
    child = seed_dependency_child(context, parent)
    before = snapshot(context)
    absolute_deadline = deadline()
    lower = System.system_time(:millisecond)

    assert {:ok, %{"card" => claimed, "token" => token}} =
             Synapsis.Workboard.execute(
               "claim",
               %{"id" => child["id"], "ownerId" => @owner},
               writer(context),
               absolute_deadline
             )

    upper = System.system_time(:millisecond)
    assert_claim(claimed, token, child, lower, upper, 1_800, "running")
    [created, ready_event, claim_event] = claimed["events"]
    assert created == hd(child["events"])

    assert ready_event == %{
             "id" => uuid(ready_event["id"]),
             "kind" => "moved",
             "at" => ready_event["at"],
             "fromStatus" => "todo",
             "toStatus" => "ready"
           }

    assert claim_event == %{
             "id" => uuid(claim_event["id"]),
             "kind" => "moved",
             "at" => claimed["updatedAt"],
             "fromStatus" => "ready",
             "toStatus" => "running"
           }

    assert ready_event["at"] > child["updatedAt"] and claim_event["at"] > ready_event["at"]
    assert_fact_transition(context, before, child, claimed, 2)
    assert get_item(snapshot(context), parent["id"]) == get_item(before, parent["id"])
    complete(context, claimed, %{"token" => token}, nil)
  end

  test "reciprocal created children normalize stable unique manifest without changing the child",
       %{context: context} do
    board(context, "alpha")
    parent = create(context, "alpha", "Parent producing child", "todo")
    child = create(context, "alpha", "Produced child", "todo")

    assert {:ok, %{"card" => linked_child}} =
             execute(writer(context), "link", %{
               "parentId" => parent["id"],
               "childId" => child["id"]
             })

    linked_parent = get_item(snapshot(context), parent["id"]).record.payload
    {claimed, token} = claim(context, linked_parent, %{}, "running", "moved")
    old_child = get_item(snapshot(context), linked_child["id"])

    done =
      complete(
        context,
        claimed,
        %{
          "token" => token,
          "summary" => "Parent completed",
          "createdCardIds" => [" " <> child["id"] <> " ", child["id"]]
        },
        "Parent completed"
      )

    assert done["metadata"]["automation"]["createdCardIds"] == [child["id"]]
    assert done["metadata"]["links"] == linked_parent["metadata"]["links"]
    assert get_item(snapshot(context), child["id"]) == old_child
    assert old_child.record.payload["status"] == "todo"

    assert {:ok, %{"card" => commented}} =
             execute(writer(context), "comment", %{
               "id" => done["id"],
               "body" => "Retain manifest"
             })

    assert Map.drop(commented["metadata"], ["comments"]) ==
             Map.drop(done["metadata"], ["comments"])

    assert {:ok, %{"card" => returned}} =
             execute(writer(context), "move", %{
               "id" => done["id"],
               "status" => "todo"
             })

    assert returned["metadata"] == commented["metadata"]

    assert {:ok, %{"card" => specified}} =
             execute(writer(context), "specify", %{
               "id" => done["id"],
               "summary" => "Reviewed manifest"
             })

    assert specified["metadata"]["automation"]["createdCardIds"] == [child["id"]]
    assert specified["metadata"]["notifications"] == done["metadata"]["notifications"]
  end

  test "ordinary older mutations retain active claim then retain completed notifications", %{
    context: context
  } do
    board(context, "alpha")

    initial =
      create(context, "alpha", "Metadata through ordinary mutations", "todo", %{
        "idempotencyKey" => "preserved-key"
      })

    {claimed, _} = claim(context, initial, %{}, "running", "moved")
    lease = claimed["metadata"]["claim"]

    assert {:ok, %{"card" => commented}} =
             execute(writer(context), "comment", %{
               "id" => initial["id"],
               "body" => "Ordinary progress"
             })

    assert commented["metadata"]["claim"] == lease

    assert {:ok, %{"card" => proofed, "proofId" => proof_id}} =
             execute(writer(context), "proof", %{
               "id" => initial["id"],
               "status" => "passed",
               "label" => "Checked"
             })

    assert proofed["metadata"]["claim"] == lease

    assert {:ok, %{"card" => attached}} =
             execute(writer(context), "attachment_add", %{
               "id" => initial["id"],
               "fileName" => "memo.txt",
               "contentBase64" => Base.encode64("memo 雪😀"),
               "mimeType" => "text/plain"
             })

    assert attached["metadata"]["claim"] == lease
    [attachment] = attached["metadata"]["attachments"]

    assert {:ok, %{"card" => returned}} =
             execute(writer(context), "move", %{"id" => initial["id"], "status" => "todo"})

    assert returned["metadata"] == attached["metadata"]
    assert returned["metadata"]["claim"] == lease

    assert {:ok, %{"card" => specified}} =
             execute(writer(context), "specify", %{
               "id" => initial["id"],
               "summary" => "Prepared summary"
             })

    assert specified["metadata"]["claim"] == lease

    assert {:ok, %{"card" => reviewed}} =
             execute(writer(context), "move", %{"id" => initial["id"], "status" => "review"})

    assert reviewed["metadata"]["claim"] == lease
    done = complete(context, reviewed, %{"proofId" => proof_id}, nil)
    assert done["metadata"]["automation"]["summary"] == "Prepared summary"
    assert done["metadata"]["proof"] == proofed["metadata"]["proof"]
    assert done["metadata"]["attachments"] == attached["metadata"]["attachments"]
    notifications = done["metadata"]["notifications"]

    assert {:ok, %{"card" => removed}} =
             execute(writer(context), "attachment_delete", %{
               "id" => initial["id"],
               "attachmentId" => attachment["id"]
             })

    assert removed["metadata"]["notifications"] == notifications

    assert {:ok, %{"card" => moved}} =
             execute(writer(context), "move", %{"id" => initial["id"], "status" => "todo"})

    assert moved["metadata"]["notifications"] == notifications

    assert {:ok, %{"card" => promoted}} =
             execute(writer(context), "promote", %{
               "id" => initial["id"],
               "reason" => "Ordinary follow-up"
             })

    assert promoted["metadata"]["notifications"] == notifications
    assert promoted["metadata"]["automation"]["summary"] == "Prepared summary"
    refute Map.has_key?(promoted["metadata"], "claim")
    assert get_item(snapshot(context), initial["id"]).record.payload == promoted
  end

  test "completion sequences span boards with historical highwater and a fresh ordinary reader",
       %{context: context} do
    board(context, "alpha")
    board(context, "beta")
    a = create(context, "alpha", "First complete", "todo")
    b = create(context, "beta", "Second complete", "todo")
    initial = snapshot(context)
    assert Store.notification_sequence(initial, deadline()) == {:ok, 0}
    {a_claim, _} = claim(context, a, %{}, "running", "moved")
    first = complete(context, a_claim, %{}, nil)
    first_point = snapshot(context)
    first_sequence = List.last(first["metadata"]["notifications"])["sequence"]
    assert Store.notification_sequence(first_point, deadline()) == {:ok, first_sequence}
    {b_claim, _} = claim(context, b, %{}, "running", "moved")
    second = complete(context, b_claim, %{}, nil)
    second_sequence = List.last(second["metadata"]["notifications"])["sequence"]
    assert second_sequence > first_sequence
    assert Store.notification_sequence(initial, deadline()) == {:ok, 0}
    assert Store.notification_sequence(first_point, deadline()) == {:ok, first_sequence}
    assert get_item(first_point, b["id"]).record.payload == b

    reader =
      Task.async(fn ->
        point = snapshot(context)

        {Store.notification_sequence(point, deadline()), get_item(point, a["id"]),
         get_item(point, b["id"])}
      end)

    assert {{:ok, ^second_sequence}, first_row, second_row} = Task.await(reader, 5_000)
    assert first_row.record.payload == first and second_row.record.payload == second
  end

  defp claim(context, previous, extra, status, kind) do
    before = snapshot(context)
    args = Map.merge(%{"id" => previous["id"], "ownerId" => @owner}, extra)
    lower = System.system_time(:millisecond)

    assert {:ok, %{"card" => actual, "token" => token} = result} =
             execute(writer(context), "claim", args)

    upper = System.system_time(:millisecond)
    assert Enum.sort(Map.keys(result)) == ["card", "token"]

    assert_claim(
      actual,
      token,
      previous,
      lower,
      upper,
      Map.get(extra, "ttlSeconds", 1_800),
      status
    )

    expected =
      changed(
        previous,
        actual,
        status,
        kind,
        Map.put(previous["metadata"], "claim", actual["metadata"]["claim"])
      )

    assert actual == expected
    assert_fact_transition(context, before, previous, actual)
    {actual, token}
  end

  defp assert_claim(actual, token, previous, lower, upper, ttl, status) do
    uuid(token)
    lease = actual["metadata"]["claim"]
    raw = lease["claimedAt"]
    assert is_integer(raw) and raw >= lower and raw <= upper

    assert lease == %{
             "ownerId" => @owner,
             "token" => token,
             "claimedAt" => raw,
             "lastHeartbeatAt" => raw,
             "expiresAt" => raw + ttl * 1_000
           }

    assert actual["status"] == status
    assert actual["updatedAt"] > previous["updatedAt"]

    if status == "running",
      do: assert(actual["startedAt"] == (previous["startedAt"] || actual["updatedAt"]))

    refute Map.has_key?(actual, "execution")
    refute Map.has_key?(actual["metadata"], "attempts")
  end

  defp heartbeat(context, previous, extra, note) do
    before = snapshot(context)
    lower = System.system_time(:millisecond)

    assert {:ok, %{"card" => actual}} =
             execute(
               writer(context),
               "heartbeat",
               Map.merge(%{"id" => previous["id"], "ownerId" => @owner}, extra)
             )

    upper = System.system_time(:millisecond)
    old = previous["metadata"]["claim"]
    lease = actual["metadata"]["claim"]
    heartbeat_at = lease["lastHeartbeatAt"]
    assert heartbeat_at >= lower and heartbeat_at <= max(upper, old["lastHeartbeatAt"] + 1)
    assert heartbeat_at > old["lastHeartbeatAt"]

    assert lease == %{
             old
             | "lastHeartbeatAt" => heartbeat_at,
               "expiresAt" => heartbeat_at + old["expiresAt"] - old["lastHeartbeatAt"]
           }

    metadata = Map.put(previous["metadata"], "claim", lease)

    metadata =
      if note do
        comment = List.last(actual["metadata"]["comments"])

        assert comment == %{
                 "id" => uuid(comment["id"]),
                 "body" => note,
                 "createdAt" => heartbeat_at
               }

        Map.put(metadata, "comments", Map.get(metadata, "comments", []) ++ [comment])
      else
        metadata
      end

    assert actual == changed(previous, actual, previous["status"], "heartbeat", metadata)
    assert_fact_transition(context, before, previous, actual)
    actual
  end

  defp release(context, previous, extra, status, kind) do
    before = snapshot(context)

    assert {:ok, %{"card" => actual}} =
             execute(
               writer(context),
               "release",
               Map.merge(%{"id" => previous["id"], "ownerId" => @owner}, extra)
             )

    assert actual ==
             changed(previous, actual, status, kind, Map.delete(previous["metadata"], "claim"))

    assert_fact_transition(context, before, previous, actual)
    actual
  end

  defp complete(context, previous, extra, summary) do
    before = snapshot(context)
    assert {:ok, prior_sequence} = Store.notification_sequence(before, deadline())
    lower = System.system_time(:millisecond)

    assert {:ok, %{"card" => actual}} =
             execute(
               writer(context),
               "complete",
               Map.merge(%{"id" => previous["id"], "ownerId" => @owner}, extra)
             )

    upper = System.system_time(:millisecond)
    notification = List.last(actual["metadata"]["notifications"])
    raw = notification["createdAt"]
    assert is_integer(raw) and raw >= lower and raw <= upper

    assert notification == %{
             "id" => uuid(notification["id"]),
             "kind" => "completed",
             "createdAt" => raw,
             "sequence" => max(prior_sequence + 1, raw * 1_000),
             "message" => summary || "Workboard card completed."
           }

    assert Store.notification_sequence(snapshot(context), deadline()) ==
             {:ok, notification["sequence"]}

    assert Store.notification_sequence(before, deadline()) == {:ok, prior_sequence}
    metadata = previous["metadata"] |> Map.delete("claim") |> Map.delete("failureCount")
    automation = metadata["automation"]
    automation = if summary, do: Map.put(automation, "summary", summary), else: automation
    child_ids = extra["createdCardIds"]

    automation =
      if child_ids do
        Map.put(automation, "createdCardIds", Enum.uniq(Enum.map(child_ids, &String.trim/1)))
      else
        Map.delete(automation, "createdCardIds")
      end

    metadata =
      metadata
      |> Map.put("automation", automation)
      |> Map.put("notifications", Map.get(metadata, "notifications", []) ++ [notification])

    metadata =
      if summary do
        comment = List.last(actual["metadata"]["comments"])
        assert comment == %{"id" => uuid(comment["id"]), "createdAt" => raw, "body" => summary}
        Map.put(metadata, "comments", Map.get(metadata, "comments", []) ++ [comment])
      else
        metadata
      end

    metadata =
      cond do
        extra["proofId"] && extra["proof"] ->
          pending_id = String.trim(extra["proofId"])

          Map.put(
            metadata,
            "proof",
            Enum.map(metadata["proof"], fn proof ->
              if proof["id"] == pending_id,
                do: Map.put(proof, "status", extra["proof"]["status"]),
                else: proof
            end)
          )

        extra["proof"] ->
          proof = List.last(actual["metadata"]["proof"])
          assert proof["createdAt"] == raw
          Map.put(metadata, "proof", Map.get(metadata, "proof", []) ++ [proof])

        true ->
          metadata
      end

    metadata =
      if extra["artifacts"] do
        artifact = List.last(actual["metadata"]["artifacts"])
        assert artifact["createdAt"] == raw
        Map.put(metadata, "artifacts", Map.get(metadata, "artifacts", []) ++ [artifact])
      else
        metadata
      end

    assert actual == changed(previous, actual, "done", "moved", metadata)
    assert_fact_transition(context, before, previous, actual)
    actual
  end

  defp changed(previous, actual, status, kind, metadata) do
    at = actual["updatedAt"]
    assert is_integer(at) and at > previous["updatedAt"]
    public = List.last(actual["events"])
    event = %{"id" => uuid(public["id"]), "kind" => kind, "at" => at}

    event =
      if kind == "moved",
        do: Map.merge(event, %{"fromStatus" => previous["status"], "toStatus" => status}),
        else: event

    assert public == event

    expected =
      Map.merge(previous, %{
        "status" => status,
        "updatedAt" => at,
        "events" => previous["events"] ++ [event],
        "metadata" => metadata
      })

    expected =
      if status == "running",
        do: Map.put(expected, "startedAt", previous["startedAt"] || at),
        else: expected

    if status == "done",
      do: Map.put(expected, "completedAt", previous["completedAt"] || at),
      else: Map.delete(expected, "completedAt")
  end

  defp assert_fact_transition(context, before, previous, next, count \\ 1) do
    after_point = snapshot(context)
    old = get_item(before, previous["id"])
    fresh = get_item(after_point, next["id"])
    revision = fresh.storage_revision
    assert revision > old.storage_revision

    assert fresh == %{
             record: %{old.record | revision: old.record.revision + count, payload: next},
             storage_revision: revision
           }

    old_board = get_board(before, old.record.board_slug)

    assert get_board(after_point, old.record.board_slug) == %{
             record: %{old_board.record | revision: old_board.record.revision + count},
             storage_revision: revision
           }

    appended = Enum.drop(next["events"], length(previous["events"]))
    assert length(appended) == count
    stored_events = events(after_point, next["id"])

    for public <- appended do
      row = Enum.find(stored_events, &(&1.record.id == public["id"]))

      assert row.record == %{
               schema_version: 1,
               id: public["id"],
               scope: context.scope,
               item_id: next["id"],
               board_id: old.record.board_id,
               kind: String.to_existing_atom(public["kind"]),
               payload: public,
               provenance: @writer
             }

      assert row.storage_revision <= revision
    end

    final_event = Enum.find(stored_events, &(&1.record.id == List.last(next["events"])["id"]))
    assert final_event.storage_revision == revision

    assert Enum.reject(
             stored_events,
             &(&1.record.id in Enum.map(appended, fn event -> event["id"] end))
           ) == events(before, previous["id"])

    for board_id <- [nil, old.record.board_id] do
      assert Enum.find(projections(after_point, board_id), &(&1.record.id == next["id"])) == %{
               record: %{
                 schema_version: 1,
                 id: next["id"],
                 scope: context.scope,
                 board_id: old.record.board_id,
                 board_slug: old.record.board_slug,
                 payload: projection(next)
               },
               storage_revision: revision
             }
    end

    assert fresh.record.provenance == @creator
    assert get_item(before, previous["id"]) == old

    if key = current_key(next),
      do:
        assert(
          Store.lookup_create_key_candidates(after_point, key, deadline()) ==
            Store.lookup_create_key_candidates(before, key, deadline())
        )
  end

  defp seed_dependency_child(context, parent) do
    point = snapshot(context)
    board = get_board(point, "alpha").record
    now = System.system_time(:millisecond)
    id = Ecto.UUID.generate()

    public = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "created",
      "at" => now,
      "toStatus" => "todo"
    }

    card = %{
      "id" => id,
      "title" => "Supplied dependency child",
      "status" => "todo",
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => now,
      "updatedAt" => now,
      "events" => [public],
      "metadata" => %{
        "automation" => %{"boardId" => "alpha"},
        "links" => [
          %{
            "id" => Ecto.UUID.generate(),
            "type" => "parent",
            "targetCardId" => parent["id"],
            "createdAt" => now
          }
        ]
      }
    }

    item = %{
      schema_version: 1,
      id: id,
      scope: context.scope,
      board_id: board.id,
      board_slug: "alpha",
      revision: 1,
      payload: card,
      provenance: @creator
    }

    event = %{
      schema_version: 1,
      id: public["id"],
      scope: context.scope,
      item_id: id,
      board_id: board.id,
      kind: :created,
      payload: public,
      provenance: @creator
    }

    change = %{
      kind: :create,
      board: %{board | revision: board.revision + 1},
      item: item,
      event: event,
      projection: projection(card),
      create_key: nil
    }

    assert {:ok, _ack} = Store.commit_item(point, change, deadline())
    card
  end

  defp board(context, slug) do
    assert {:ok, %{"board" => result}} =
             execute(context, "board_create", %{"id" => slug, "name" => String.capitalize(slug)})

    result
  end

  defp create(context, slug, title, status, extra \\ %{}) do
    assert {:ok, %{"card" => card}} =
             execute(
               context,
               "create",
               Map.merge(%{"title" => title, "status" => status, "boardId" => slug}, extra)
             )

    card
  end

  defp projection(card) do
    base =
      Map.take(card, [
        "id",
        "title",
        "status",
        "priority",
        "agentId",
        "updatedAt",
        "position",
        "createdAt"
      ])
      |> Map.put("boardId", card["metadata"]["automation"]["boardId"])

    base =
      if tenant = card["metadata"]["automation"]["tenant"],
        do: Map.put(base, "tenant", tenant),
        else: base

    case card["metadata"]["links"] do
      nil ->
        base

      links ->
        base
        |> Map.put(
          "parents",
          for(link <- links, link["type"] == "parent", do: link["targetCardId"])
        )
        |> Map.put(
          "children",
          for(link <- links, link["type"] == "child", do: link["targetCardId"])
        )
    end
  end

  defp current_key(card) do
    a = card["metadata"]["automation"]
    if a["idempotencyKey"], do: {a["tenant"], a["boardId"], a["idempotencyKey"]}
  end

  defp assert_read(context, card, text) do
    point = snapshot(context)

    assert execute(context, "read", %{"id" => card["id"]}) ==
             {:ok, %{"card" => card, "workerContext" => text}}

    assert snapshot(context) == point
    assert get_item(snapshot(context), card["id"]).record.payload == card
  end

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
    point
  end

  defp get_item(point, id) do
    assert {:ok, row} = Store.get_item(point, id, deadline())
    row
  end

  defp get_board(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp projections(point, board_id) do
    opts = if board_id, do: [limit: 100, board_id: board_id], else: [limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end

  defp uuid(id) do
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    id
  end

  defp writer(context), do: %{context | provenance: @writer}

  defp execute(context, action, args),
    do: Synapsis.Workboard.execute(action, args, context, deadline())

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
