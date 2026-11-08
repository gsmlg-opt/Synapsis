defmodule Synapsis.Workboard.CoreAttachmentFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Independent source-shaped fixtures from OpenClaw 488631c and batch381's
  # explicit Concord adaptation contract. No implementation candidate inspected.
  # All provenance is supplied fixture JSON, not native/model invocation evidence.
  @creator %{
    "sessionId" => "38100000-0000-4000-8000-000000000001",
    "agentId" => "38100000-0000-4000-8000-000000000002",
    "runId" => "fixture:381:create",
    "incarnation" => 14,
    "invocationId" => "fixture:381:create-invoke",
    "toolCallId" => "fixture:381:create-call",
    "extra" => %{"json" => [nil, false, 1.5, "雪😀"]}
  }
  @uploader %{
    "sessionId" => "38100000-0000-4000-8000-000000000011",
    "agentId" => "38100000-0000-4000-8000-000000000012",
    "runId" => "fixture:381:upload",
    "incarnation" => 15,
    "invocationId" => "fixture:381:upload-invoke",
    "toolCallId" => "fixture:381:upload-call",
    "extra" => %{"retained" => [true, nil, "café"]}
  }
  @editor %{
    "sessionId" => "38100000-0000-4000-8000-000000000021",
    "agentId" => "38100000-0000-4000-8000-000000000022",
    "runId" => "fixture:381:edit",
    "incarnation" => 16,
    "invocationId" => "fixture:381:edit-invoke",
    "toolCallId" => "fixture:381:edit-call",
    "extra" => %{"json" => %{"ordinary" => [7, "雪😀"]}}
  }
  @automation %{
    "boardId" => "research",
    "tenant" => "tenant-old",
    "idempotencyKey" => "attachment-key",
    "skills" => ["inspect", "review"],
    "workspace" => %{"kind" => "dir", "path" => "/supplied/workspace"},
    "maxRuntimeSeconds" => 120,
    "maxRetries" => 2
  }
  @binary "AP8BgA=="
  @unicode "6Zuq8J+YgAo="

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()

    %{
      context: %{
        scope: "fixture:381:core/opaque:雪/" <> Ecto.UUID.generate(),
        provenance: @creator
      }
    }
  end

  test "normalized rich and blank optional uploads retain canonical binary bytes and duplicate identity then delete precisely",
       %{context: context} do
    board(context, "research")
    original = create(context)

    {first, a} =
      add(
        context,
        original,
        %{
          "fileName" => " \uFEFFcapture 雪😀.bin\u00A0 ",
          "contentBase64" => @binary,
          "mimeType" => " application/octet-stream ",
          "note" => " First supplied note\nKeep newline. "
        },
        %{
          "fileName" => "capture 雪😀.bin",
          "byteSize" => 4,
          "mimeType" => "application/octet-stream",
          "note" => "First supplied note\nKeep newline."
        }
      )

    assert_read_blob(context, a, @binary, <<0, 255, 1, 128>>)
    historical = snapshot(context)
    first_blob = attachment(historical, a["id"])

    {second, b} =
      add(
        context,
        first,
        %{
          "fileName" => " duplicate.bin ",
          "contentBase64" => @binary,
          "mimeType" => " \t ",
          "note" => "\uFEFF\u00A0"
        },
        %{"fileName" => "duplicate.bin", "byteSize" => 4}
      )

    assert a["id"] != b["id"]
    assert second["metadata"]["attachments"] == [a, b]
    assert_read_blob(context, b, @binary, <<0, 255, 1, 128>>)
    assert attachment(snapshot(context), a["id"]) == first_blob
    after_first_delete = delete(context, second, a)
    assert after_first_delete["metadata"]["attachments"] == [b]
    assert Store.get_attachment(snapshot(context), a["id"], deadline()) == :not_found
    assert attachment(historical, a["id"]) == first_blob
    assert_read_blob(context, b, @binary, <<0, 255, 1, 128>>)
    after_last_delete = delete(context, after_first_delete, b)
    assert after_last_delete["metadata"] == %{"automation" => @automation}
    assert Store.get_attachment(snapshot(context), b["id"], deadline()) == :not_found

    assert execute(context, "read", %{"id" => original["id"]}) ==
             {:ok,
              %{"card" => after_last_delete, "workerContext" => base_context(after_last_delete)}}
  end

  test "attachments follow proof and artifacts in context and survive comments lifecycle specify board changes and key return",
       %{context: context} do
    board(context, "research")
    board(context, "delivery")
    initial = create(context)

    {uploaded, a} =
      add(
        context,
        initial,
        %{
          "fileName" => " report 雪😀.txt ",
          "contentBase64" => @unicode,
          "mimeType" => " text/plain ",
          "note" => " Supplied Unicode content "
        },
        %{
          "fileName" => "report 雪😀.txt",
          "byteSize" => 8,
          "mimeType" => "text/plain",
          "note" => "Supplied Unicode content"
        }
      )

    blob = attachment(snapshot(context), a["id"])
    proofed = add_proof(context, uploaded)
    commented = comment(context, proofed, "Review after attachment")
    running = move(context, commented, "running")
    returned = move(context, running, "todo")
    point = snapshot(context)
    old_source = get_board(point, "research")
    old_target = get_board(point, "delivery")
    old_item = get_item(point, initial["id"])
    old_key = key(returned)
    old_key_row = Store.lookup_create_key_candidates(point, old_key, deadline())

    assert {:ok, %{"card" => actual}} =
             execute(edit(context), "specify", %{
               "id" => returned["id"],
               "title" => "Clarified attachment",
               "boardId" => "delivery",
               "tenant" => "tenant-new",
               "summary" => "Accepted report"
             })

    expected =
      expect_specify(
        returned,
        actual,
        "Clarified attachment",
        "delivery",
        "tenant-new",
        "Accepted report"
      )

    assert actual == expected
    current = snapshot(context)
    revision = get_item(current, initial["id"]).storage_revision

    assert get_item(current, initial["id"]) == %{
             record: %{
               old_item.record
               | revision: old_item.record.revision + 1,
                 board_id: old_target.record.id,
                 board_slug: "delivery",
                 payload: expected
             },
             storage_revision: revision
           }

    assert get_board(current, "research") == %{
             record: %{old_source.record | revision: old_source.record.revision + 1},
             storage_revision: revision
           }

    assert get_board(current, "delivery") == %{
             record: %{old_target.record | revision: old_target.record.revision + 1},
             storage_revision: revision
           }

    assert Store.lookup_create_key_candidates(current, old_key, deadline()) == :not_found
    assert Store.lookup_create_key_candidates(point, old_key, deadline()) == old_key_row

    assert Store.lookup_create_key_candidates(current, key(expected), deadline()) ==
             {:ok, %{ids: [initial["id"]], storage_revision: revision}}

    assert projections(current, old_source.record.id) == []

    assert projections(current, old_target.record.id) == [
             projected(context, expected, old_target.record.id, revision)
           ]

    assert projections(current, nil) == [
             projected(context, expected, old_target.record.id, revision)
           ]

    assert_new_event(
      context,
      point,
      current,
      expected,
      old_target.record.id,
      :specified,
      @editor,
      revision
    )

    assert attachment(current, a["id"]) == blob
    assert attachment(point, a["id"]) == blob
    assert expected["startedAt"] == running["startedAt"]
    assert expected["metadata"]["attachments"] == [a]
    assert_read_blob(context, a, @unicode, "雪😀\n")
    stable = facts(context, expected["id"])

    assert execute(context, "create", %{
             "title" => "Ignored duplicate",
             "boardId" => "delivery",
             "tenant" => "tenant-new",
             "idempotencyKey" => "attachment-key"
           }) == {:ok, %{"card" => expected}}

    assert facts(context, expected["id"]) == stable

    text =
      header(expected) <>
        "\n\n## Notes\nAcceptance\nKeep this line." <>
        "\n\n## Recent comments\n- Review after attachment\n- Accepted report" <>
        "\n\n## Proof\n- passed: Supplied proof" <>
        "\n\n## Artifacts\n- Supplied proof" <>
        "\n\n## Attachments\n- report 雪😀.txt · 8 bytes · text/plain · Supplied Unicode content" <>
        automation_context(expected)

    assert execute(context, "read", %{"id" => expected["id"]}) ==
             {:ok, %{"card" => expected, "workerContext" => text}}

    deleted = delete(context, expected, a)
    assert deleted["metadata"]["proof"] == expected["metadata"]["proof"]
    assert deleted["metadata"]["artifacts"] == expected["metadata"]["artifacts"]
    assert Store.get_attachment(snapshot(context), a["id"], deadline()) == :not_found
    assert attachment(point, a["id"]) == blob
  end

  test "an explicitly Data-supplied missing-proof fixture clears its diagnostic and computed warning on ordinary upload",
       %{context: context} do
    board(context, "research")
    # This is a valid durable Data fixture, not evidence of a Core diagnostic producer.
    card = seed_done_diagnostic(context)
    before = snapshot(context)

    assert execute(context, "read", %{"id" => card["id"]}) ==
             {:ok,
              %{
                "card" => card,
                "workerContext" =>
                  base_context(card) <>
                    "\n\n## Active diagnostics\n- warning: Done card has no proof"
              }}

    {uploaded, a} =
      add(context, card, %{"fileName" => " completion.txt ", "contentBase64" => @unicode}, %{
        "fileName" => "completion.txt",
        "byteSize" => 8
      })

    assert uploaded["metadata"] == %{"automation" => @automation, "attachments" => [a]}
    assert get_item(before, card["id"]).record.payload == card

    text =
      header(uploaded) <>
        "\n\n## Notes\nAcceptance\nKeep this line." <>
        "\n\n## Attachments\n- completion.txt · 8 bytes" <> automation_context(uploaded)

    assert execute(context, "read", %{"id" => card["id"]}) ==
             {:ok, %{"card" => uploaded, "workerContext" => text}}

    assert_read_blob(context, a, @unicode, "雪😀\n")
    deleted = delete(context, uploaded, a)
    assert deleted["completedAt"] == card["completedAt"]

    assert execute(context, "read", %{"id" => card["id"]}) ==
             {:ok,
              %{
                "card" => deleted,
                "workerContext" =>
                  base_context(deleted) <>
                    "\n\n## Active diagnostics\n- warning: Done card has no proof"
              }}
  end

  test "normal creator completion leaves full attachment blobs and cards for a distinct fresh reader and ordinary deletion",
       %{context: context} do
    creator =
      Task.async(fn ->
        board(context, "research")
        card = create(context)

        {one, a} =
          add(context, card, %{"fileName" => "binary.bin", "contentBase64" => @binary}, %{
            "fileName" => "binary.bin",
            "byteSize" => 4
          })

        {two, b} =
          add(
            context,
            one,
            %{
              "fileName" => "Unicode.txt",
              "contentBase64" => @unicode,
              "mimeType" => "text/plain"
            },
            %{"fileName" => "Unicode.txt", "byteSize" => 8, "mimeType" => "text/plain"}
          )

        %{card: two, a: a, b: b, facts: facts(context, two["id"]), point: snapshot(context)}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        assert facts(context, written.card["id"]) == written.facts
        assert_read_blob(context, written.a, @binary, <<0, 255, 1, 128>>)
        assert_read_blob(context, written.b, @unicode, "雪😀\n")

        text =
          header(written.card) <>
            "\n\n## Notes\nAcceptance\nKeep this line." <>
            "\n\n## Attachments\n- binary.bin · 4 bytes\n- Unicode.txt · 8 bytes · text/plain" <>
            automation_context(written.card)

        assert execute(context, "read", %{"id" => written.card["id"]}) ==
                 {:ok, %{"card" => written.card, "workerContext" => text}}

        written.card
      end)

    assert Task.await(reader, 30_000) == written.card
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    first_deleted = delete(context, written.card, written.a)
    all_deleted = delete(context, first_deleted, written.b)
    assert all_deleted["metadata"] == %{"automation" => @automation}

    assert attachment(written.point, written.a["id"]).record.payload ==
             blob_payload(written.a, @binary)

    assert attachment(written.point, written.b["id"]).record.payload ==
             blob_payload(written.b, @unicode)
  end

  defp add(context, previous, args, fields) do
    point = snapshot(context)
    lower = System.system_time(:millisecond)
    supplied = Map.put(args, "id", " " <> previous["id"] <> " ")
    assert {:ok, result} = execute(upload(context), "attachment_add", supplied)
    upper = System.system_time(:millisecond)
    assert Map.keys(result) == ["card"]
    actual = result["card"]
    entry = List.last(actual["metadata"]["attachments"])
    at = entry["createdAt"]
    assert is_integer(at) and at >= lower and at <= upper

    entry =
      Map.merge(fields, %{
        "id" => uuid(entry["id"]),
        "cardId" => previous["id"],
        "createdAt" => at
      })

    assert List.last(actual["metadata"]["attachments"]) == entry
    assert actual["updatedAt"] > previous["updatedAt"] and actual["updatedAt"] >= at

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "attachment_added",
      "at" => actual["updatedAt"]
    }

    old_entries = Map.get(previous["metadata"], "attachments", [])
    ids = [previous["id"] | Enum.map(previous["events"] ++ old_entries, & &1["id"])]
    refute entry["id"] in ids
    refute event["id"] in [entry["id"] | ids]

    metadata =
      previous["metadata"]
      |> Map.delete("diagnostics")
      |> Map.put("attachments", old_entries ++ [entry])

    expected = %{
      previous
      | "updatedAt" => actual["updatedAt"],
        "metadata" => metadata,
        "events" => previous["events"] ++ [event]
    }

    assert actual == expected
    current = snapshot(context)

    revision =
      assert_facts(context, point, current, previous, expected, :attachment_added, @uploader)

    assert attachment(current, entry["id"]) == %{
             record: %{
               schema_version: 1,
               id: entry["id"],
               scope: context.scope,
               item_id: previous["id"],
               payload: blob_payload(entry, args["contentBase64"]),
               provenance: @uploader
             },
             storage_revision: revision
           }

    for old <- old_entries,
        do: assert(attachment(current, old["id"]) == attachment(point, old["id"]))

    {expected, entry}
  end

  defp delete(context, previous, entry) do
    point = snapshot(context)
    blob = attachment(point, entry["id"])
    assert blob.record.provenance == @uploader

    assert {:ok, result} =
             execute(edit(context), "attachment_delete", %{
               "id" => previous["id"],
               "attachmentId" => entry["id"]
             })

    assert Map.keys(result) == ["card"]
    actual = result["card"]
    assert is_integer(actual["updatedAt"]) and actual["updatedAt"] > previous["updatedAt"]

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "edited",
      "at" => actual["updatedAt"]
    }

    remaining = Enum.reject(previous["metadata"]["attachments"], &(&1["id"] == entry["id"]))

    metadata =
      if remaining == [],
        do: Map.delete(previous["metadata"], "attachments"),
        else: Map.put(previous["metadata"], "attachments", remaining)

    expected = %{
      previous
      | "updatedAt" => actual["updatedAt"],
        "metadata" => metadata,
        "events" => previous["events"] ++ [event]
    }

    assert actual == expected
    current = snapshot(context)
    assert_facts(context, point, current, previous, expected, :edited, @editor)
    assert Store.get_attachment(current, entry["id"], deadline()) == :not_found
    assert attachment(point, entry["id"]) == blob

    for other <- remaining,
        do: assert(attachment(current, other["id"]) == attachment(point, other["id"]))

    expected
  end

  defp assert_read_blob(context, entry, encoded, bytes) do
    before = facts(context, entry["cardId"])

    assert execute(context, "attachment_read", %{"id" => " " <> entry["id"] <> " "}) ==
             {:ok, blob_payload(entry, encoded)}

    assert Base.decode64!(encoded) == bytes
    assert byte_size(bytes) == entry["byteSize"]
    assert facts(context, entry["cardId"]) == before
  end

  defp assert_facts(context, before, current, previous, card, kind, provenance) do
    old_item = get_item(before, card["id"])
    old_board = get_board(before, old_item.record.board_slug)
    item = get_item(current, card["id"])
    revision = item.storage_revision
    assert revision > old_item.storage_revision

    assert item.record == %{
             old_item.record
             | revision: old_item.record.revision + 1,
               payload: card
           }

    assert item.record.provenance == @creator

    assert get_board(current, old_item.record.board_slug) == %{
             record: %{old_board.record | revision: old_board.record.revision + 1},
             storage_revision: revision
           }

    assert_new_event(
      context,
      before,
      current,
      card,
      old_board.record.id,
      kind,
      provenance,
      revision
    )

    row = projected(context, card, old_board.record.id, revision)

    for board_id <- [nil, old_board.record.id] do
      assert Enum.filter(projections(current, board_id), &(&1.record.id == card["id"])) == [row]

      assert Enum.reject(projections(current, board_id), &(&1.record.id == card["id"])) ==
               Enum.reject(projections(before, board_id), &(&1.record.id == card["id"]))
    end

    assert Store.lookup_create_key_candidates(current, key(card), deadline()) ==
             Store.lookup_create_key_candidates(before, key(card), deadline())

    assert get_item(before, card["id"]) == old_item
    assert old_item.record.payload == previous
    assert get_board(before, old_item.record.board_slug) == old_board
    revision
  end

  defp assert_new_event(context, before, current, card, board_id, kind, provenance, revision) do
    event = List.last(card["events"])

    assert Enum.filter(events(current, card["id"]), &(&1.record.id == event["id"])) == [
             %{
               record: %{
                 schema_version: 1,
                 id: event["id"],
                 scope: context.scope,
                 item_id: card["id"],
                 board_id: board_id,
                 kind: kind,
                 payload: event,
                 provenance: provenance
               },
               storage_revision: revision
             }
           ]

    assert Enum.reject(events(current, card["id"]), &(&1.record.id == event["id"])) ==
             events(before, card["id"])
  end

  defp board(context, slug) do
    assert {:ok, %{"board" => b}} =
             execute(context, "board_create", %{"id" => slug, "name" => String.capitalize(slug)})

    at = b["createdAt"]
    assert is_integer(at) and at > 0

    assert b == %{
             "id" => slug,
             "name" => String.capitalize(slug),
             "createdAt" => at,
             "updatedAt" => at
           }

    b
  end

  defp create(context) do
    assert {:ok, %{"card" => card}} =
             execute(
               context,
               "create",
               Map.merge(
                 @automation,
                 %{
                   "title" => "Attachment card café 雪😀",
                   "notes" => "Acceptance\nKeep this line.",
                   "priority" => "high",
                   "labels" => ["review", "雪😀"],
                   "agentId" => "fixture-agent"
                 }
               )
             )

    at = card["createdAt"]
    assert is_integer(at) and at > 0
    [event] = card["events"]

    expected = %{
      "id" => uuid(card["id"]),
      "title" => "Attachment card café 雪😀",
      "notes" => "Acceptance\nKeep this line.",
      "status" => "todo",
      "priority" => "high",
      "labels" => ["review", "雪😀"],
      "agentId" => "fixture-agent",
      "position" => 1000,
      "createdAt" => at,
      "updatedAt" => at,
      "metadata" => %{"automation" => @automation},
      "events" => [
        %{"id" => uuid(event["id"]), "kind" => "created", "at" => at, "toStatus" => "todo"}
      ]
    }

    assert card == expected
    card
  end

  defp comment(context, previous, body) do
    point = snapshot(context)

    assert {:ok, %{"card" => actual}} =
             execute(edit(context), "comment", %{"id" => previous["id"], "body" => body})

    c = List.last(actual["metadata"]["comments"])
    at = c["createdAt"]
    assert is_integer(at) and at > 0 and at <= actual["updatedAt"]
    assert actual["updatedAt"] > previous["updatedAt"]
    c = %{"id" => uuid(c["id"]), "body" => body, "createdAt" => at}

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
            Map.get(previous["metadata"], "comments", []) ++ [c]
          )
    }

    assert actual == expected
    current = snapshot(context)
    assert_facts(context, point, current, previous, expected, :commented, @editor)
    assert_retained_blobs(point, current, previous)
    expected
  end

  defp move(context, previous, status) do
    point = snapshot(context)

    assert {:ok, %{"card" => actual}} =
             execute(edit(context), "move", %{"id" => previous["id"], "status" => status})

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

    assert actual == expected
    current = snapshot(context)
    assert_facts(context, point, current, previous, expected, :moved, @editor)
    assert_retained_blobs(point, current, previous)
    expected
  end

  defp add_proof(context, previous) do
    point = snapshot(context)
    lower = System.system_time(:millisecond)

    assert {:ok, %{"card" => actual, "proofId" => proof_id}} =
             execute(edit(context), "proof", %{
               "id" => previous["id"],
               "status" => "passed",
               "label" => "Supplied proof",
               "artifactPath" => "/supplied/proof.log"
             })

    upper = System.system_time(:millisecond)
    p = List.last(actual["metadata"]["proof"])
    at = p["createdAt"]
    assert is_integer(at) and at >= lower and at <= upper
    assert actual["updatedAt"] >= at and actual["updatedAt"] > previous["updatedAt"]

    p = %{
      "id" => uuid(proof_id),
      "status" => "passed",
      "label" => "Supplied proof",
      "createdAt" => at
    }

    a = %{
      "id" => uuid(List.last(actual["metadata"]["artifacts"])["id"]),
      "path" => "/supplied/proof.log",
      "label" => "Supplied proof",
      "createdAt" => at
    }

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "proof_added",
      "at" => actual["updatedAt"]
    }

    expected = %{
      previous
      | "updatedAt" => actual["updatedAt"],
        "events" => previous["events"] ++ [event],
        "metadata" => Map.merge(previous["metadata"], %{"proof" => [p], "artifacts" => [a]})
    }

    assert actual == expected
    current = snapshot(context)
    assert_facts(context, point, current, previous, expected, :proof_added, @editor)
    assert_retained_blobs(point, current, previous)
    expected
  end

  defp expect_specify(previous, actual, title, slug, tenant, body) do
    e = List.last(actual["events"])
    at = e["at"]
    assert is_integer(at) and at > 0 and at <= actual["updatedAt"]
    assert actual["updatedAt"] > previous["updatedAt"]
    e = %{"id" => uuid(e["id"]), "kind" => "specified", "at" => at}

    c = %{
      "id" => uuid(List.last(actual["metadata"]["comments"])["id"]),
      "body" => body,
      "createdAt" => at
    }

    metadata =
      previous["metadata"]
      |> Map.put(
        "automation",
        Map.merge(previous["metadata"]["automation"], %{
          "boardId" => slug,
          "tenant" => tenant,
          "summary" => body
        })
      )
      |> Map.put("comments", Map.get(previous["metadata"], "comments", []) ++ [c])

    %{
      previous
      | "title" => title,
        "updatedAt" => actual["updatedAt"],
        "events" => previous["events"] ++ [e],
        "metadata" => metadata
    }
  end

  defp seed_done_diagnostic(context) do
    point = snapshot(context)
    b = get_board(point, "research").record
    at = System.system_time(:millisecond)
    id = Ecto.UUID.generate()
    event = %{"id" => Ecto.UUID.generate(), "kind" => "created", "at" => at, "toStatus" => "done"}

    diagnostic = %{
      "kind" => "missing_proof",
      "severity" => "warning",
      "title" => "Done card has no proof",
      "detail" => "The card is marked done without proof or an attached artifact.",
      "firstSeenAt" => at,
      "lastSeenAt" => at,
      "count" => 1,
      "actions" => [%{"kind" => "add_proof", "label" => "Add proof"}]
    }

    card = %{
      "id" => id,
      "title" => "Attachment card café 雪😀",
      "notes" => "Acceptance\nKeep this line.",
      "status" => "done",
      "priority" => "high",
      "labels" => ["review", "雪😀"],
      "agentId" => "fixture-agent",
      "position" => 1000,
      "createdAt" => at,
      "updatedAt" => at,
      "completedAt" => at,
      "events" => [event],
      "metadata" => %{"automation" => @automation, "diagnostics" => [diagnostic]}
    }

    item = %{
      schema_version: 1,
      id: id,
      scope: context.scope,
      board_id: b.id,
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
      board_id: b.id,
      kind: :created,
      payload: event,
      provenance: @creator
    }

    next = %{b | revision: b.revision + 1}

    assert {:ok, ack} =
             Store.commit_item(
               point,
               %{
                 kind: :create,
                 board: next,
                 item: item,
                 event: envelope,
                 projection: projection(card),
                 create_key: key(card)
               },
               deadline()
             )

    assert ack == %{
             board: next,
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

  defp assert_retained_blobs(before, current, card) do
    for entry <- Map.get(card["metadata"], "attachments", []) do
      assert attachment(current, entry["id"]) == attachment(before, entry["id"])
    end
  end

  defp blob_payload(entry, encoded),
    do: %{"version" => 1, "attachment" => entry, "contentBase64" => encoded}

  defp header(card),
    do:
      "# Workboard card #{card["id"]}\nTitle: #{card["title"]}\nStatus: #{card["status"]}\nPriority: #{card["priority"]}\nBoard: #{card["metadata"]["automation"]["boardId"]}\nAgent: fixture-agent"

  defp automation_context(card) do
    a = card["metadata"]["automation"]

    text =
      "\n\n## Automation\nTenant: #{a["tenant"]}\nBoard: #{a["boardId"]}\nSkills: inspect, review\nWorkspace: dir /supplied/workspace"

    if a["summary"], do: text <> "\nSummary: " <> a["summary"], else: text
  end

  defp base_context(card),
    do: header(card) <> "\n\n## Notes\nAcceptance\nKeep this line." <> automation_context(card)

  defp projection(card) do
    a = card["metadata"]["automation"]

    base = %{
      "id" => card["id"],
      "title" => card["title"],
      "status" => card["status"],
      "priority" => card["priority"],
      "agentId" => "fixture-agent",
      "boardId" => a["boardId"],
      "tenant" => a["tenant"],
      "updatedAt" => card["updatedAt"],
      "position" => card["position"],
      "createdAt" => card["createdAt"]
    }

    if card["metadata"]["diagnostics"],
      do: Map.put(base, "diagnostics", card["metadata"]["diagnostics"]),
      else: base
  end

  defp projected(context, card, board_id, revision),
    do: %{
      record: %{
        schema_version: 1,
        id: card["id"],
        scope: context.scope,
        board_id: board_id,
        board_slug: card["metadata"]["automation"]["boardId"],
        payload: projection(card)
      },
      storage_revision: revision
    }

  defp facts(context, id) do
    point = snapshot(context)
    item = get_item(point, id)
    card = item.record.payload
    blobs = Enum.map(Map.get(card["metadata"], "attachments", []), &attachment(point, &1["id"]))

    %{
      item: item,
      board: get_board(point, item.record.board_slug),
      events: events(point, id),
      projections: projections(point, nil),
      board_projections: projections(point, item.record.board_id),
      key: Store.lookup_create_key_candidates(point, key(card), deadline()),
      blobs: blobs
    }
  end

  defp key(card) do
    a = card["metadata"]["automation"]
    {a["tenant"], a["boardId"], a["idempotencyKey"]}
  end

  defp upload(context), do: %{context | provenance: @uploader}
  defp edit(context), do: %{context | provenance: @editor}

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

  defp get_board(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp attachment(point, id) do
    assert {:ok, row} = Store.get_attachment(point, id, deadline())
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
