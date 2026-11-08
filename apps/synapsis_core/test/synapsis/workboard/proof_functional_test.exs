defmodule Synapsis.Workboard.CoreProofFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Independent ordinary fixtures derived from unchanged OpenClaw 488631c.
  # Caller provenance is invented JSON test data, never native/model evidence.
  # No workboard380 product candidate was available to or read by this author.
  @creator %{
    "sessionId" => "38000000-0000-4000-8000-000000000001",
    "agentId" => "38000000-0000-4000-8000-000000000002",
    "runId" => "fixture:workboard380:create",
    "incarnation" => 12,
    "invocationId" => "fixture:workboard380:invoke-create",
    "toolCallId" => "fixture:workboard380:call-create",
    "extra" => %{"ordinary" => [nil, false, 1.25, "café 雪😀"], "nested" => %{"v" => 2}}
  }
  @writer %{
    "sessionId" => "38000000-0000-4000-8000-000000000011",
    "agentId" => "38000000-0000-4000-8000-000000000012",
    "runId" => "fixture:workboard380:proof",
    "incarnation" => 13,
    "invocationId" => "fixture:workboard380:invoke-proof",
    "toolCallId" => "fixture:workboard380:call-proof",
    "extra" => %{"json" => [nil, true, 7, %{"text" => "雪😀"}]}
  }
  @automation %{
    "boardId" => "research",
    "tenant" => "tenant-fixture",
    "idempotencyKey" => "proof-key",
    "skills" => ["inspect", "review"],
    "workspace" => %{"kind" => "dir", "path" => "/supplied/workspace"},
    "maxRuntimeSeconds" => 120,
    "maxRetries" => 2
  }

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:workboard380/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "proof-only records normalize source fields and append one proof including blank optionals and default unknown",
       %{context: context} do
    board(context)
    original = create(context)

    first =
      proof(
        context,
        original,
        %{
          "id" => " \uFEFF" <> original["id"] <> "\u00A0 ",
          "status" => "passed",
          "label" => " \uFEFFReview café 雪😀\u00A0 ",
          "command" => " mix test scoped\nkeep this step ",
          "note" => " Ordinary supplied note\nKeep inner newline. ",
          "url" => " \t ",
          "artifactPath" => " \t "
        },
        %{
          "status" => "passed",
          "label" => "Review café 雪😀",
          "command" => "mix test scoped\nkeep this step",
          "note" => "Ordinary supplied note\nKeep inner newline."
        },
        nil
      )

    second =
      proof(
        context,
        first,
        %{
          "label" => " \t ",
          "command" => "\uFEFF",
          "note" => "\u00A0",
          "url" => " ",
          "artifactPath" => "\n"
        },
        %{"status" => "unknown"},
        nil
      )

    third =
      proof(
        context,
        second,
        %{"status" => "skipped", "note" => "Not needed for this fixture"},
        %{"status" => "skipped", "note" => "Not needed for this fixture"},
        nil
      )

    assert Enum.map(third["metadata"]["proof"], & &1["status"]) == [
             "passed",
             "unknown",
             "skipped"
           ]

    assert third["metadata"]["automation"] == @automation
    refute Map.has_key?(third["metadata"], "artifacts")

    assert_read(
      context,
      third,
      context_text(
        third,
        [],
        [
          "- passed: Review café 雪😀",
          "- unknown: undefined",
          "- skipped: Not needed for this fixture"
        ],
        []
      )
    )
  end

  test "artifact path URL and both each append exactly one proof and one artifact in a single revision",
       %{context: context} do
    board(context)
    initial = create(context)

    path =
      proof(
        context,
        initial,
        %{
          "status" => "passed",
          "artifactPath" => " /supplied/screens/雪😀.png ",
          "note" => " Path recorded "
        },
        %{"status" => "passed", "note" => "Path recorded"},
        %{"path" => "/supplied/screens/雪😀.png"}
      )

    url =
      proof(
        context,
        path,
        %{
          "status" => "unknown",
          "url" => " https://example.test/evidence?q=café ",
          "command" => " supplied check "
        },
        %{
          "status" => "unknown",
          "url" => "https://example.test/evidence?q=café",
          "command" => "supplied check"
        },
        %{"url" => "https://example.test/evidence?q=café"}
      )

    both =
      proof(
        context,
        url,
        %{
          "status" => "skipped",
          "label" => " Report 雪😀 ",
          "artifactPath" => " /supplied/report.json ",
          "url" => " https://example.test/report ",
          "note" => " Metadata only "
        },
        %{
          "status" => "skipped",
          "label" => "Report 雪😀",
          "url" => "https://example.test/report",
          "note" => "Metadata only"
        },
        %{
          "label" => "Report 雪😀",
          "path" => "/supplied/report.json",
          "url" => "https://example.test/report"
        }
      )

    assert length(both["metadata"]["proof"]) == 3
    assert length(both["metadata"]["artifacts"]) == 3

    assert Enum.map(tl(both["events"]), & &1["kind"]) == [
             "proof_added",
             "proof_added",
             "proof_added"
           ]

    assert_read(
      context,
      both,
      context_text(
        both,
        [],
        ["- passed: Path recorded", "- unknown: supplied check", "- skipped: Report 雪😀"],
        ["- /supplied/screens/雪😀.png", "- https://example.test/evidence?q=café", "- Report 雪😀"]
      )
    )
  end

  test "evidence composes with comment move specify and current-key create return without replacing evidence",
       %{context: context} do
    board(context)
    initial = create(context)

    evidenced =
      proof(
        context,
        initial,
        %{
          "status" => "passed",
          "note" => "Checked ordinary result",
          "artifactPath" => "/supplied/result.log"
        },
        %{"status" => "passed", "note" => "Checked ordinary result"},
        %{"path" => "/supplied/result.log"}
      )

    commented = comment(context, evidenced, "After proof 雪😀")
    running = move(context, commented, "running")
    returned = move(context, running, "todo")
    before = snapshot(context)

    assert {:ok, %{"card" => clarified}} =
             execute(writer(context), "specify", %{
               "id" => returned["id"],
               "title" => "Clarified proof card",
               "summary" => "Clarified acceptance"
             })

    at = List.last(clarified["events"])["at"]
    assert is_integer(at) and at > 0 and at <= clarified["updatedAt"]

    event = %{
      "id" => uuid(List.last(clarified["events"])["id"]),
      "kind" => "specified",
      "at" => at
    }

    entry = %{
      "id" => uuid(List.last(clarified["metadata"]["comments"])["id"]),
      "body" => "Clarified acceptance",
      "createdAt" => at
    }

    assert clarified["updatedAt"] > returned["updatedAt"]

    expected = %{
      returned
      | "title" => "Clarified proof card",
        "updatedAt" => clarified["updatedAt"],
        "events" => returned["events"] ++ [event],
        "metadata" => %{
          returned["metadata"]
          | "automation" => Map.put(@automation, "summary", "Clarified acceptance"),
            "comments" => returned["metadata"]["comments"] ++ [entry]
        }
    }

    assert clarified == expected
    assert_facts(context, before, snapshot(context), returned, expected, :specified)

    final =
      proof(
        context,
        expected,
        %{"note" => "After specification"},
        %{"status" => "unknown", "note" => "After specification"},
        nil
      )

    assert final["startedAt"] == running["startedAt"]
    stable = facts(context, final["id"])

    assert {:ok, %{"card" => ^final}} =
             execute(context, "create", %{
               "title" => "Ignored repeat",
               "boardId" => "research",
               "tenant" => "tenant-fixture",
               "idempotencyKey" => "proof-key"
             })

    assert facts(context, final["id"]) == stable

    assert_read(
      context,
      final,
      context_text(
        final,
        [],
        ["- passed: Checked ordinary result", "- unknown: After specification"],
        ["- /supplied/result.log"]
      )
    )
  end

  test "valid Data-created missing-proof fixture clears on proof and Data proof ACK publishes all closed-shape facts",
       %{context: context} do
    board(context)
    # Explicit Data fixture; this diagnostic was supplied by the test, not generated
    # by a native session or a supported diagnostic-producing Core action.
    original = seed_diagnostic(context)
    before = snapshot(context)

    assert_read(
      context,
      original,
      context_text(original, [], [], []) <>
        "\n\n## Active diagnostics\n- warning: Done card has no proof"
    )

    cleared =
      proof(
        context,
        original,
        %{"note" => "Supplied completion evidence"},
        %{"status" => "unknown", "note" => "Supplied completion evidence"},
        nil
      )

    refute Map.has_key?(cleared["metadata"], "diagnostics")
    assert get_item(before, original["id"]).record.payload == original

    assert_read(
      context,
      cleared,
      context_text(cleared, [], ["- unknown: Supplied completion evidence"], [])
    )

    point = snapshot(context)
    item = get_item(point, cleared["id"]).record
    current_board = get_board(point).record
    now = max(System.system_time(:millisecond), cleared["updatedAt"] + 1)

    entry = %{
      "id" => Ecto.UUID.generate(),
      "status" => "passed",
      "createdAt" => now,
      "note" => "Direct Data fixture evidence"
    }

    artifact = %{
      "id" => Ecto.UUID.generate(),
      "createdAt" => now,
      "path" => "/supplied/direct.log"
    }

    event = %{"id" => Ecto.UUID.generate(), "kind" => "proof_added", "at" => now}

    card = %{
      cleared
      | "updatedAt" => now,
        "events" => cleared["events"] ++ [event],
        "metadata" =>
          Map.merge(cleared["metadata"], %{
            "proof" => cleared["metadata"]["proof"] ++ [entry],
            "artifacts" => [artifact]
          })
    }

    next_item = %{item | revision: item.revision + 1, payload: card}
    next_board = %{current_board | revision: current_board.revision + 1}

    envelope = %{
      schema_version: 1,
      id: event["id"],
      scope: context.scope,
      item_id: card["id"],
      board_id: current_board.id,
      kind: :proof_added,
      payload: event,
      provenance: @writer
    }

    assert {:ok, ack} =
             Store.commit_item(
               point,
               %{
                 kind: :proof,
                 board: next_board,
                 item: next_item,
                 event: envelope,
                 projection: projection(card),
                 create_key: nil
               },
               deadline()
             )

    revision = ack.storage_revision
    assert is_integer(revision) and revision > get_item(point, card["id"]).storage_revision

    assert ack == %{
             board: next_board,
             item: next_item,
             event: envelope,
             storage_revision: revision
           }

    after_point = snapshot(context)
    assert get_item(after_point, card["id"]) == %{record: next_item, storage_revision: revision}
    assert_facts(context, point, after_point, cleared, card, :proof_added)

    assert_read(
      context,
      card,
      context_text(
        card,
        [],
        ["- unknown: Supplied completion evidence", "- passed: Direct Data fixture evidence"],
        ["- /supplied/direct.log"]
      )
    )
  end

  test "ordinary creator completion leaves fresh readers complete cards and source summary precedence",
       %{context: context} do
    creator =
      Task.async(fn ->
        board(context)

        Enum.map(
          [
            {"summary", "Automation result", "Comment result", "Proof result"},
            {"comment", nil, "Comment result", "Proof result"},
            {"proof", nil, nil, "Last proof result 雪😀"}
          ],
          fn {agent, summary, body, note} ->
            done =
              create(context, %{
                "title" => "Done " <> agent,
                "agentId" => agent,
                "idempotencyKey" => "done-" <> agent
              })

            done = if summary, do: specify_summary(context, done, summary), else: done
            done = if body, do: comment(context, done, body), else: done

            done =
              proof(
                context,
                done,
                %{"note" => "Earlier proof note"},
                %{"status" => "unknown", "note" => "Earlier proof note"},
                nil
              )

            done =
              proof(
                context,
                done,
                %{"status" => "passed", "note" => note},
                %{"status" => "passed", "note" => note},
                nil
              )

            done =
              proof(
                context,
                done,
                %{"status" => "skipped", "label" => "Supplement"},
                %{"status" => "skipped", "label" => "Supplement"},
                nil
              )

            done = move(context, done, "done")

            active =
              create(context, %{
                "title" => "Follow up " <> agent,
                "agentId" => agent,
                "idempotencyKey" => "active-" <> agent
              })

            active =
              proof(
                context,
                active,
                %{"label" => "Follow up evidence", "url" => "https://example.test/followup"},
                %{
                  "status" => "unknown",
                  "label" => "Follow up evidence",
                  "url" => "https://example.test/followup"
                },
                %{"label" => "Follow up evidence", "url" => "https://example.test/followup"}
              )

            result = summary || body || note

            text =
              context_text(
                active,
                ["- #{done["id"]} #{done["title"]}: #{result}"],
                ["- unknown: Follow up evidence"],
                ["- Follow up evidence"]
              )

            assert_read(context, active, text)
            %{done: done, active: active, text: text}
          end
        )
        |> Enum.map(fn row ->
          Map.merge(row, %{
            active_facts: facts(context, row.active["id"]),
            done_facts: facts(context, row.done["id"])
          })
        end)
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        Enum.map(written, fn row ->
          assert_read(context, row.active, row.text)

          assert {:ok, %{"card" => done, "workerContext" => _}} =
                   execute(context, "read", %{"id" => row.done["id"]})

          assert done == row.done
          assert facts(context, done["id"]) == row.done_facts
          assert facts(context, row.active["id"]) == row.active_facts
          row.active
        end)
      end)

    assert Task.await(reader, 30_000) == Enum.map(written, & &1.active)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
  end

  defp proof(context, previous, args, fields, artifact_fields) do
    point = snapshot(context)
    lower = System.system_time(:millisecond)
    supplied = Map.put_new(args, "id", previous["id"])
    assert {:ok, result} = execute(writer(context), "proof", supplied)
    upper = System.system_time(:millisecond)
    assert Map.keys(result) |> Enum.sort() == ["card", "proofId"]
    actual = result["card"]
    proof_id = uuid(result["proofId"])
    entry = List.last(actual["metadata"]["proof"])
    at = entry["createdAt"]
    assert is_integer(at) and at >= lower and at <= upper
    expected_entry = Map.merge(fields, %{"id" => proof_id, "createdAt" => at})
    assert entry == expected_entry
    assert actual["updatedAt"] >= at and actual["updatedAt"] > previous["updatedAt"]
    old_metadata = previous["metadata"]
    old_proof = Map.get(old_metadata, "proof", [])
    old_artifacts = Map.get(old_metadata, "artifacts", [])

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "proof_added",
      "at" => actual["updatedAt"]
    }

    identifiers = [
      previous["id"] | Enum.map(previous["events"] ++ old_proof ++ old_artifacts, & &1["id"])
    ]

    refute proof_id in identifiers
    refute event["id"] in (identifiers ++ [proof_id])

    metadata =
      old_metadata |> Map.delete("diagnostics") |> Map.put("proof", old_proof ++ [expected_entry])

    metadata =
      if artifact_fields do
        artifact = List.last(actual["metadata"]["artifacts"])
        artifact_id = uuid(artifact["id"])
        refute artifact_id in (identifiers ++ [proof_id, event["id"]])
        expected_artifact = Map.merge(artifact_fields, %{"id" => artifact_id, "createdAt" => at})
        assert artifact == expected_artifact
        Map.put(metadata, "artifacts", old_artifacts ++ [expected_artifact])
      else
        metadata
      end

    expected = %{
      previous
      | "updatedAt" => actual["updatedAt"],
        "events" => previous["events"] ++ [event],
        "metadata" => metadata
    }

    assert actual == expected
    assert supplied == Map.put_new(args, "id", previous["id"])
    assert_facts(context, point, snapshot(context), previous, expected, :proof_added)
    expected
  end

  defp assert_facts(context, before, after_point, previous, card, kind) do
    old_item = get_item(before, card["id"])
    old_board = get_board(before)
    item = get_item(after_point, card["id"])
    board_row = get_board(after_point)
    revision = item.storage_revision
    assert revision > old_item.storage_revision

    assert item.record == %{
             old_item.record
             | revision: old_item.record.revision + 1,
               payload: card
           }

    assert item.record.provenance == @creator

    assert board_row == %{
             record: %{old_board.record | revision: old_board.record.revision + 1},
             storage_revision: revision
           }

    public = List.last(card["events"])

    event = %{
      record: %{
        schema_version: 1,
        id: public["id"],
        scope: context.scope,
        item_id: card["id"],
        board_id: old_board.record.id,
        kind: kind,
        payload: public,
        provenance: @writer
      },
      storage_revision: revision
    }

    assert Enum.filter(events(after_point, card["id"]), &(&1.record.id == public["id"])) == [
             event
           ]

    assert Enum.reject(events(after_point, card["id"]), &(&1.record.id == public["id"])) ==
             events(before, card["id"])

    projected = %{
      record: %{
        schema_version: 1,
        id: card["id"],
        scope: context.scope,
        board_id: old_board.record.id,
        board_slug: "research",
        payload: projection(card)
      },
      storage_revision: revision
    }

    for board_id <- [nil, old_board.record.id] do
      assert Enum.filter(projections(after_point, board_id), &(&1.record.id == card["id"])) == [
               projected
             ]

      assert Enum.reject(projections(after_point, board_id), &(&1.record.id == card["id"])) ==
               Enum.reject(projections(before, board_id), &(&1.record.id == card["id"]))
    end

    key = current_key(card)

    assert Store.lookup_create_key_candidates(after_point, key, deadline()) ==
             Store.lookup_create_key_candidates(before, key, deadline())

    assert get_item(before, previous["id"]) == old_item
    assert old_item.record.payload == previous
    assert get_board(before) == old_board
  end

  defp board(context) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{"id" => "research", "name" => "Research"})

    at = board["createdAt"]
    assert is_integer(at) and at > 0

    assert board == %{
             "id" => "research",
             "name" => "Research",
             "createdAt" => at,
             "updatedAt" => at
           }

    board
  end

  defp create(context, overrides \\ %{}) do
    fields = %{
      "title" => "Proof card café 雪😀",
      "notes" => "Acceptance\nKeep this line.",
      "priority" => "high",
      "labels" => ["review", "雪😀"],
      "agentId" => "fixture-agent"
    }

    args = Map.merge(Map.merge(fields, @automation), overrides)
    point = snapshot(context)

    position =
      projections(point, nil)
      |> Enum.filter(&(&1.record.payload["status"] == "todo"))
      |> Enum.reduce(0, &max(&1.record.payload["position"], &2))
      |> Kernel.+(1000)

    assert {:ok, %{"card" => card}} = execute(context, "create", args)
    at = card["createdAt"]
    assert is_integer(at) and at > 0
    automation = Map.merge(@automation, Map.take(overrides, Map.keys(@automation)))
    [event] = card["events"]

    expected =
      Map.merge(Map.merge(fields, Map.take(overrides, Map.keys(fields))), %{
        "id" => uuid(card["id"]),
        "status" => "todo",
        "position" => position,
        "createdAt" => at,
        "updatedAt" => at,
        "metadata" => %{"automation" => automation},
        "events" => [
          %{"id" => uuid(event["id"]), "kind" => "created", "at" => at, "toStatus" => "todo"}
        ]
      })

    assert is_integer(card["position"]) and card["position"] > 0
    assert card == expected
    card
  end

  defp comment(context, previous, body) do
    point = snapshot(context)

    assert {:ok, %{"card" => actual}} =
             execute(writer(context), "comment", %{"id" => previous["id"], "body" => body})

    entry = List.last(actual["metadata"]["comments"])
    at = entry["createdAt"]
    assert is_integer(at) and at > 0 and at <= actual["updatedAt"]
    assert actual["updatedAt"] > previous["updatedAt"]
    entry = %{"id" => uuid(entry["id"]), "createdAt" => at, "body" => body}

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "comment_added",
      "at" => actual["updatedAt"]
    }

    expected = %{
      previous
      | "updatedAt" => actual["updatedAt"],
        "events" => previous["events"] ++ [event],
        "metadata" =>
          Map.put(
            previous["metadata"],
            "comments",
            Map.get(previous["metadata"], "comments", []) ++ [entry]
          )
    }

    assert actual == expected
    assert_facts(context, point, snapshot(context), previous, expected, :commented)
    expected
  end

  defp move(context, previous, status) do
    point = snapshot(context)

    assert {:ok, %{"card" => actual}} =
             execute(writer(context), "move", %{"id" => previous["id"], "status" => status})

    at = actual["updatedAt"]
    assert is_integer(at) and at > previous["updatedAt"]

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "moved",
      "at" => at,
      "fromStatus" => previous["status"],
      "toStatus" => status
    }

    expected = %{
      previous
      | "status" => status,
        "updatedAt" => at,
        "events" => previous["events"] ++ [event]
    }

    expected =
      if status == "running",
        do: Map.put(expected, "startedAt", previous["startedAt"] || at),
        else: expected

    expected =
      if status == "done",
        do: Map.put(expected, "completedAt", previous["completedAt"] || at),
        else: Map.delete(expected, "completedAt")

    assert actual == expected
    assert_facts(context, point, snapshot(context), previous, expected, :moved)
    expected
  end

  defp specify_summary(context, previous, body) do
    point = snapshot(context)

    assert {:ok, %{"card" => card}} =
             execute(writer(context), "specify", %{"id" => previous["id"], "summary" => body})

    at = List.last(card["events"])["at"]
    assert is_integer(at) and at > 0 and at <= card["updatedAt"]
    assert card["updatedAt"] > previous["updatedAt"]
    event = %{"id" => uuid(List.last(card["events"])["id"]), "kind" => "specified", "at" => at}

    entry = %{
      "id" => uuid(List.last(card["metadata"]["comments"])["id"]),
      "body" => body,
      "createdAt" => at
    }

    metadata =
      previous["metadata"]
      |> Map.put("automation", Map.put(previous["metadata"]["automation"], "summary", body))
      |> Map.put("comments", Map.get(previous["metadata"], "comments", []) ++ [entry])

    expected = %{
      previous
      | "updatedAt" => card["updatedAt"],
        "events" => previous["events"] ++ [event],
        "metadata" => metadata
    }

    assert card == expected
    assert_facts(context, point, snapshot(context), previous, expected, :specified)
    expected
  end

  defp seed_diagnostic(context) do
    point = snapshot(context)
    board_row = get_board(point).record
    now = System.system_time(:millisecond)
    id = Ecto.UUID.generate()

    event = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "created",
      "at" => now,
      "toStatus" => "done"
    }

    diagnostic = %{
      "kind" => "missing_proof",
      "severity" => "warning",
      "title" => "Done card has no proof",
      "detail" => "The card is marked done without proof or an attached artifact.",
      "firstSeenAt" => now,
      "lastSeenAt" => now,
      "count" => 1,
      "actions" => [%{"kind" => "add_proof", "label" => "Add proof"}]
    }

    card = %{
      "id" => id,
      "title" => "Data diagnostic fixture",
      "status" => "done",
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => now,
      "updatedAt" => now,
      "completedAt" => now,
      "events" => [event],
      "metadata" => %{"automation" => @automation, "diagnostics" => [diagnostic]}
    }

    item = %{
      schema_version: 1,
      id: id,
      scope: context.scope,
      board_id: board_row.id,
      board_slug: "research",
      revision: 1,
      payload: card,
      provenance: @creator
    }

    envelope = %{
      schema_version: 1,
      id: event["id"],
      scope: context.scope,
      item_id: id,
      board_id: board_row.id,
      kind: :created,
      payload: event,
      provenance: @creator
    }

    next_board = %{board_row | revision: board_row.revision + 1}

    assert {:ok, ack} =
             Store.commit_item(
               point,
               %{
                 kind: :create,
                 board: next_board,
                 item: item,
                 event: envelope,
                 projection: projection(card),
                 create_key: current_key(card)
               },
               deadline()
             )

    assert ack == %{
             board: next_board,
             item: item,
             event: envelope,
             storage_revision: ack.storage_revision
           }

    assert get_item(snapshot(context), id) == %{
             record: item,
             storage_revision: ack.storage_revision
           }

    card
  end

  defp context_text(card, recent, proof_lines, artifact_lines) do
    automation = card["metadata"]["automation"]

    text =
      "# Workboard card #{card["id"]}\nTitle: #{card["title"]}\nStatus: #{card["status"]}\nPriority: #{card["priority"]}\nBoard: research\nAgent: #{Map.get(card, "agentId", "(default)")}"

    text = if card["notes"], do: text <> "\n\n## Notes\n" <> card["notes"], else: text
    comments = Enum.map(Map.get(card["metadata"], "comments", []), &("- " <> &1["body"]))
    text = section(text, "Recent comments", comments)
    text = section(text, "Proof", proof_lines)
    text = section(text, "Artifacts", artifact_lines)
    text = section(text, "Recent done work by #{card["agentId"]}", recent)

    text =
      text <>
        "\n\n## Automation\nTenant: tenant-fixture\nBoard: research\nSkills: inspect, review\nWorkspace: dir /supplied/workspace"

    if automation["summary"], do: text <> "\nSummary: " <> automation["summary"], else: text
  end

  defp section(text, _, []), do: text

  defp section(text, heading, entries),
    do: text <> "\n\n## " <> heading <> "\n" <> Enum.join(entries, "\n")

  defp projection(card) do
    base = %{
      "id" => card["id"],
      "title" => card["title"],
      "status" => card["status"],
      "priority" => card["priority"],
      "boardId" => "research",
      "tenant" => "tenant-fixture",
      "updatedAt" => card["updatedAt"],
      "position" => card["position"],
      "createdAt" => card["createdAt"]
    }

    base = if card["agentId"], do: Map.put(base, "agentId", card["agentId"]), else: base

    if card["metadata"]["diagnostics"],
      do: Map.put(base, "diagnostics", card["metadata"]["diagnostics"]),
      else: base
  end

  defp facts(context, id) do
    point = snapshot(context)
    card = get_item(point, id).record.payload

    %{
      item: get_item(point, id),
      board: get_board(point),
      events: events(point, id),
      scope_projection: projections(point, nil),
      board_projection: projections(point, get_board(point).record.id),
      key: Store.lookup_create_key_candidates(point, current_key(card), deadline())
    }
  end

  defp assert_read(context, card, text) do
    assert execute(context, "read", %{"id" => card["id"]}) ==
             {:ok, %{"card" => card, "workerContext" => text}}
  end

  defp current_key(card) do
    a = card["metadata"]["automation"]
    {a["tenant"], a["boardId"], a["idempotencyKey"]}
  end

  defp writer(context), do: %{context | provenance: @writer}

  defp execute(context, action, args),
    do: Synapsis.Workboard.execute(action, args, context, deadline())

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
    point
  end

  defp get_item(point, id) do
    assert {:ok, row} = Store.get_item(point, id, deadline())
    row
  end

  defp get_board(point) do
    assert {:ok, row} = Store.get_board(point, "research", deadline())
    row
  end

  defp projections(point, board_id) do
    opts = if board_id, do: [board_id: board_id, limit: 100], else: [limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp uuid(value) do
    assert is_binary(value)
    assert {:ok, ^value} = Ecto.UUID.cast(value)

    assert String.match?(
             value,
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
           )

    value
  end
end
