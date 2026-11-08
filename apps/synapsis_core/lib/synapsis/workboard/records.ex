defmodule Synapsis.Workboard.Records do
  @moduledoc false

  alias Synapsis.Filesystem.TextBudget

  # Ordinary record algorithms adapted from OpenClaw 488631c, MIT License.
  # Copyright (c) 2026 OpenClaw Foundation
  #
  # Permission is hereby granted, free of charge, to any person obtaining a copy
  # of this software and associated documentation files (the "Software"), to deal
  # in the Software without restriction, including without limitation the rights
  # to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  # copies of the Software, and to permit persons to whom the Software is
  # furnished to do so, subject to the following conditions:
  #
  # The above copyright notice and this permission notice shall be included in all
  # copies or substantial portions of the Software.
  #
  # THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  # IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  # FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  # AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  # LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  # OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  # SOFTWARE.

  @statuses ~w(triage backlog todo scheduled ready running review blocked done)
  @priorities ~w(low normal high urgent)
  @create_keys ~w(title notes status priority labels agentId tenant boardId idempotencyKey skills workspace maxRuntimeSeconds maxRetries parents createdByCardId scheduledAt)
  @move_card_keys ~w(id title notes status priority labels agentId position createdAt updatedAt metadata events startedAt completedAt)
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def normalize(action, input) do
    try do
      unless json_map?(input), do: invalid("arguments must be a JSON object")
      {:ok, normalize_action(action, input)}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  defp normalize_action("board_create", input) do
    fields!(input, ~w(id name description))

    compact(%{
      "id" => board_slug(input["id"]),
      "name" => bounded(input["name"], 120),
      "description" => bounded(input["description"], 1000)
    })
  end

  defp normalize_action("board_archive", input) do
    fields!(input, ~w(id archived))
    %{"id" => board_slug(input["id"]), "archived" => Map.get(input, "archived", true)}
  end

  defp normalize_action("board_delete", input) do
    fields!(input, ~w(id))
    slug = board_slug(input["id"])
    if slug == "default", do: invalid("default board cannot be deleted")
    %{"id" => slug}
  end

  defp normalize_action("boards", input) do
    fields!(input, [])
    %{}
  end

  defp normalize_action("create", input) do
    fields!(input, @create_keys)
    title = bounded(input["title"], 180)
    unless title, do: invalid("title is required")

    parents = parent_strings(input["parents"])

    automation =
      compact(%{
        "boardId" => board_slug(input["boardId"]),
        "tenant" => bounded(input["tenant"], 80),
        "idempotencyKey" => bounded(input["idempotencyKey"], 160),
        "createdByCardId" =>
          bounded(input["createdByCardId"], 120) || if(length(parents) == 1, do: hd(parents)),
        "skills" => strings(input["skills"], 80, 20, :reject),
        "workspace" => workspace(input["workspace"]),
        "maxRuntimeSeconds" => positive_integer(input["maxRuntimeSeconds"]),
        "maxRetries" => positive_integer(input["maxRetries"]),
        "scheduledAt" => scheduled_timestamp(input["scheduledAt"])
      })
      |> Map.reject(fn {_key, value} -> value == [] end)

    compact(%{
      "title" => title,
      "notes" => bounded(input["notes"], 4000),
      "status" => create_status(input["status"], parents),
      "parents" => parents,
      "priority" => enum(input["priority"], @priorities, "normal"),
      "labels" => strings(input["labels"], 40, 12, :cap),
      "agentId" => optional_string(input["agentId"]),
      "automation" => automation
    })
  end

  defp normalize_action("list", input) do
    fields!(input, ~w(status agentId tenant boardId limit))
    limit = if is_number(input["limit"]), do: input["limit"], else: 50

    compact(
      Map.merge(Map.take(input, ~w(status agentId tenant)), %{
        "boardId" => optional_board_slug(input["boardId"]),
        "limit" => min(200, max(1, floor(limit)))
      })
    )
  end

  defp normalize_action("stats", input) do
    fields!(input, ~w(boardId))
    compact(%{"boardId" => optional_board_slug(input["boardId"])})
  end

  defp normalize_action("read", input) do
    fields!(input, ~w(id))
    %{"id" => card_id(input["id"])}
  end

  defp normalize_action("comment", input) do
    fields!(input, ~w(id body))
    body = bounded(input["body"], 2000)
    unless body, do: invalid("comment body is required")
    %{"id" => card_id(input["id"]), "body" => body}
  end

  defp normalize_action("attachment_add", input) do
    fields!(input, ~w(id fileName contentBase64 mimeType note))
    Map.put(input, "id", card_id(input["id"]))
  end

  defp normalize_action("attachment_read", input) do
    fields!(input, ~w(id))
    %{"id" => card_id(input["id"])}
  end

  defp normalize_action("attachment_delete", input) do
    fields!(input, ~w(id attachmentId))
    %{"id" => card_id(input["id"]), "attachmentId" => card_id(input["attachmentId"])}
  end

  defp normalize_action("proof", input) do
    fields!(input, ~w(id status label command url note artifactPath))
    Map.put(input, "id", card_id(input["id"]))
  end

  defp normalize_action("specify", input) do
    fields!(
      input,
      ~w(id title notes agentId priority labels boardId tenant skills workspace maxRuntimeSeconds maxRetries summary)
    )

    Map.put(input, "id", card_id(input["id"]))
  end

  defp normalize_action("link", input) do
    fields!(input, ~w(parentId childId))
    %{"parentId" => card_id(input["parentId"]), "childId" => card_id(input["childId"])}
  end

  defp normalize_action("move", input) do
    fields!(input, ~w(id status position))
    Map.put(input, "id", card_id(input["id"]))
  end

  defp normalize_action("promote", input) do
    fields!(input, ~w(id reason force))

    compact(%{
      "id" => card_id(input["id"]),
      "reason" => bounded(input["reason"], 1000),
      "force" => input["force"] === true
    })
  end

  defp normalize_action("claim", input) do
    fields!(input, ~w(id ownerId token ttlSeconds))
    owner = bounded(input["ownerId"], 120)
    unless owner, do: invalid("claim ownerId is required")

    compact(%{
      "id" => card_id(input["id"]),
      "ownerId" => owner,
      "token" => bounded(input["token"], 160),
      "ttlSeconds" => if(is_number(input["ttlSeconds"]), do: max(1, floor(input["ttlSeconds"])))
    })
  end

  defp normalize_action("heartbeat", input) do
    fields!(input, ~w(id token ownerId note))
    input |> Map.put("id", card_id(input["id"])) |> Map.put("note", bounded(input["note"], 400))
  end

  defp normalize_action("release", input) do
    fields!(input, ~w(id token ownerId note status))
    Map.put(input, "id", card_id(input["id"]))
  end

  defp normalize_action("complete", input) do
    fields!(input, ~w(id ownerId token summary proof proofId artifacts createdCardIds))
    Map.put(input, "id", card_id(input["id"]))
  end

  defp normalize_action("decompose", input) do
    fields!(input, ~w(id ownerId token children summary completeParent))
    children = input["children"]

    unless is_list(children) and length(children) in 1..20,
      do: invalid("decompose requires 1 to 20 children")

    Map.put(input, "id", card_id(input["id"]))
  end

  defp normalize_action("notify_subscribe", input) do
    fields!(input, ~w(boardId cardId sessionKey runId target eventKinds))

    subscription =
      compact(%{
        "boardId" => board_slug(input["boardId"]),
        "cardId" => bounded(input["cardId"], 120),
        "sessionKey" => bounded(input["sessionKey"], 240),
        "runId" => bounded(input["runId"], 512),
        "target" => bounded(input["target"], 240),
        "eventKinds" => notification_kinds(input["eventKinds"])
      })

    unless Enum.any?(~w(cardId sessionKey runId target), &Map.has_key?(subscription, &1)),
      do: invalid("notification subscription needs cardId, sessionKey, runId, or target")

    subscription
  end

  defp normalize_action("notify_list", input) do
    fields!(input, ~w(boardId cardId))

    compact(%{
      "boardId" => optional_board_slug(input["boardId"]),
      "cardId" => bounded(input["cardId"], 120)
    })
  end

  defp normalize_action("notify_events", input) do
    fields!(input, ~w(subscriptionId boardId cardId limit))

    compact(%{
      "subscriptionId" => bounded(input["subscriptionId"], 120),
      "boardId" => optional_board_slug(input["boardId"]),
      "cardId" => bounded(input["cardId"], 120),
      "limit" => notification_limit(input["limit"])
    })
  end

  defp normalize_action("notify_advance", input) do
    fields!(input, ~w(subscriptionId limit))

    %{
      "subscriptionId" => notification_id(input["subscriptionId"]),
      "limit" => notification_limit(input["limit"])
    }
  end

  defp normalize_action("notify_unsubscribe", input) do
    fields!(input, ~w(id))
    %{"id" => notification_id(input["id"])}
  end

  defp normalize_action(_, _), do: invalid("unsupported operation")

  defp notification_id(value) do
    id = bounded(value, 120)
    unless id, do: invalid("notification subscription id is required")
    id
  end

  defp notification_limit(value) do
    limit = if is_number(value), do: value, else: 50
    min(200, max(1, floor(limit)))
  end

  defp notification_kinds(value) do
    entries =
      cond do
        is_binary(value) -> String.split(value, ",")
        is_list(value) -> value
        true -> []
      end

    kinds =
      Enum.reduce(entries, [], fn entry, kinds ->
        kind = optional_string(entry)

        unless kind in ~w(completed failed stale),
          do: invalid("notification kind must be one of: completed, failed, stale")

        if kind in kinds, do: kinds, else: kinds ++ [kind]
      end)

    if kinds == [], do: nil, else: kinds
  end

  # Subscription transforms read complete cards without applying mutation allowlists.
  def notification_subscription(input, id, now),
    do: Map.merge(input, %{"id" => id, "createdAt" => now, "updatedAt" => now})

  def notification_subscriptions(subscriptions, input) do
    subscriptions
    |> Enum.filter(fn subscription ->
      Enum.all?(~w(boardId cardId), fn key ->
        is_nil(input[key]) or subscription[key] == input[key]
      end)
    end)
    |> Enum.sort_by(&{&1["createdAt"], &1["id"]})
  end

  def notification_selection(input, subscription) do
    subscription = subscription || %{}
    card_id = nullish(subscription["cardId"], input["cardId"])
    board_id = if is_nil(card_id), do: nullish(subscription["boardId"], input["boardId"])
    {card_id, board_id}
  end

  def notification_events(cards, input, subscription) do
    {card_id, board_id} = notification_selection(input, subscription)
    subscription = subscription || %{}

    cards
    |> Enum.filter(fn card ->
      not truthy?(get_in(card, ["metadata", "archivedAt"])) and
        (is_nil(card_id) or card["id"] == card_id) and
        (is_nil(board_id) or get_in(card, ["metadata", "automation", "boardId"]) == board_id)
    end)
    |> Enum.flat_map(fn card ->
      metadata = card["metadata"] || %{}
      notifications = nullish(metadata["notifications"], [])
      events = notifications ++ stale_notification(card, metadata["stale"])
      session_key = card_notification_field(card, "sessionKey")
      run_id = card_notification_field(card, "runId")

      Enum.filter(events, fn event ->
        (not truthy?(subscription["sessionKey"]) or
           nullish(event["sessionKey"], session_key) == subscription["sessionKey"]) and
          (not truthy?(subscription["runId"]) or
             nullish(event["runId"], run_id) == subscription["runId"]) and
          (subscription["eventKinds"] in [nil, []] or
             event["kind"] in subscription["eventKinds"]) and
          after_notification_cursor?(event, subscription)
      end)
    end)
    |> Enum.sort(&(compare_notifications(&1, &2) != :gt))
    |> Enum.take(input["limit"])
  end

  def advance_notification_subscription(subscription, events, now) do
    last = List.last(events)

    subscription
    |> Map.merge(%{
      "lastEventAt" => last["createdAt"],
      "lastEventId" => last["id"],
      "updatedAt" => now
    })
    |> Map.delete("deliveredEventIds")
    |> then(fn advanced ->
      if Map.has_key?(last, "sequence"),
        do: Map.put(advanced, "lastEventSequence", last["sequence"]),
        else: Map.delete(advanced, "lastEventSequence")
    end)
  end

  defp after_notification_cursor?(event, subscription) do
    if Map.has_key?(subscription, "lastEventAt") do
      cursor = %{
        "createdAt" => subscription["lastEventAt"],
        "id" => nullish(subscription["lastEventId"], "")
      }

      cursor =
        if Map.has_key?(subscription, "lastEventSequence"),
          do: Map.put(cursor, "sequence", subscription["lastEventSequence"]),
          else: cursor

      compare_notifications(event, cursor) == :gt
    else
      true
    end
  end

  # Binary ID comparison covers canonical UUIDs, synthetic stale IDs and the
  # qualified ASCII source vectors; arbitrary imported Unicode collation is unqualified.
  defp compare_notifications(left, right) do
    cond do
      left["createdAt"] != right["createdAt"] ->
        compare_notification_value(left["createdAt"], right["createdAt"])

      Map.has_key?(left, "sequence") and Map.has_key?(right, "sequence") ->
        case compare_notification_value(left["sequence"], right["sequence"]) do
          :eq -> compare_notification_value(left["id"], right["id"])
          order -> order
        end

      Map.has_key?(left, "sequence") ->
        :lt

      Map.has_key?(right, "sequence") ->
        :gt

      true ->
        compare_notification_value(left["id"], right["id"])
    end
  end

  defp compare_notification_value(left, right) when left < right, do: :lt
  defp compare_notification_value(left, right) when left > right, do: :gt
  defp compare_notification_value(_, _), do: :eq

  defp stale_notification(_card, stale) when stale in [nil, false, 0, ""], do: []

  defp stale_notification(card, stale) do
    event = %{
      "id" => "stale:#{card["id"]}:#{stale["detectedAt"]}",
      "kind" => "stale",
      "createdAt" => stale["detectedAt"],
      "sequence" => stale["detectedAt"] * 1000,
      "message" => stale["reason"]
    }

    event =
      Enum.reduce(~w(sessionKey runId), event, fn field, event ->
        value = card_notification_field(card, field)
        if truthy?(value), do: Map.put(event, field, value), else: event
      end)

    [event]
  end

  defp card_notification_field(card, field) do
    execution = card["execution"]
    fallback = if is_map(execution), do: execution[field]
    nullish(card[field], fallback)
  end

  defp nullish(nil, fallback), do: fallback
  defp nullish(value, _fallback), do: value

  @default_claim_ttl 30 * 60 * 1000
  @maximum_date 8_640_000_000_000_000

  # Pure lifecycle transforms. Execution, attempts and trusted launch authority
  # remain explicitly unsupported on the target; occupancy still reads full peers.
  def claim(card, input, event_id, claim_now, update_now, parents_done) do
    workflow_result(fn ->
      supported_move_card!(card)
      if truthy?(get_in(card, ["metadata", "archivedAt"])), do: invalid("card is archived")
      existing = get_in(card, ["metadata", "claim"])

      active =
        not is_nil(existing) and
          (future_claim?(existing, claim_now) or
             (card["status"] == "running" and not reclaimable?(existing, claim_now)))

      if parent_ids(card) != [] and card["status"] != "ready" and not active do
        if card["status"] == "blocked",
          do: invalid("card is blocked; use workboard_unblock before claiming")

        unless parents_done, do: invalid("card dependencies are not done")
      end

      if card["status"] == "scheduled", do: invalid("card is scheduled for later")
      retries = get_in(card, ["metadata", "automation", "maxRetries"])

      if truthy?(retries) and (get_in(card, ["metadata", "failureCount"]) || 0) > retries,
        do: invalid("card exhausted its retry budget")

      if active, do: invalid("card already claimed by " <> existing["ownerId"])

      duration =
        if input["ttlSeconds"],
          do: min(@maximum_date, trunc(input["ttlSeconds"]) * 1000),
          else: @default_claim_ttl

      claim = %{
        "ownerId" => input["ownerId"],
        "token" => input["token"],
        "claimedAt" => claim_now,
        "lastHeartbeatAt" => claim_now,
        "expiresAt" => add_duration(claim_now, duration)
      }

      metadata =
        card
        |> Map.get("metadata", %{})
        |> clear_diagnostics(["stranded_ready"])
        |> Map.put("claim", claim)

      status = if card["status"] in ~w(backlog todo ready), do: "running", else: card["status"]
      workflow_update(card, status, metadata, event_id, update_now, false)
    end)
  end

  def heartbeat(card, input, comment_id, event_id, heartbeat_now, update_now) do
    workflow_result(fn ->
      supported_move_card!(card)
      claim = get_in(card, ["metadata", "claim"])
      unless claim, do: invalid("card is not claimed")
      assert_claim_identity!(claim, input)
      now = max(heartbeat_now, claim["lastHeartbeatAt"] + 1)
      expires = claim["expiresAt"]

      extension =
        if truthy?(expires) do
          duration =
            if expires > claim["claimedAt"],
              do: expires - claim["lastHeartbeatAt"],
              else: @default_claim_ttl

          add_duration(now, max(1, duration))
        end

      next_claim =
        claim
        |> Map.put("lastHeartbeatAt", now)
        |> Map.delete("expiresAt")
        |> optional_put("expiresAt", extension)

      metadata =
        card
        |> Map.get("metadata", %{})
        |> clear_diagnostics(["running_without_heartbeat"])
        |> Map.put("claim", next_claim)
        |> append_workflow_comment(input["note"], comment_id, now)

      workflow_update(card, card["status"], metadata, event_id, update_now, false)
    end)
  end

  def release(card, input, event_id, update_now) do
    workflow_result(fn ->
      supported_move_card!(card)
      claim = get_in(card, ["metadata", "claim"])
      if claim, do: assert_claim_identity!(claim, input)
      status = enum(input["status"], @statuses, card["status"])
      metadata = card |> Map.get("metadata", %{}) |> Map.delete("claim")
      workflow_update(card, status, metadata, event_id, update_now, Map.has_key?(input, "status"))
    end)
  end

  def next_notification_sequence(previous, now), do: max(previous + 1, max(0, trunc(now)) * 1000)

  def complete(card, input, ids, outer_now, update_now, sequence) do
    workflow_result(fn ->
      supported_move_card!(card)
      assert_completion_identity!(card, input)
      summary = bounded(input["summary"], 2000)
      created = strings(input["createdCardIds"], 120, 20, :reject)
      proof_id = bounded(input["proofId"], 120)

      if Map.has_key?(input, "proofId") and is_nil(proof_id),
        do: invalid("proofId must be a non-empty string")

      proof = completion_proof(input["proof"], ids.proof, outer_now)

      metadata =
        card
        |> Map.get("metadata", %{})
        |> Map.delete("claim")
        |> Map.put("failureCount", 0)
        |> clear_diagnostics(["missing_proof"])

      proofs = resolve_completion_proof(Map.get(metadata, "proof", []), proof, proof_id)

      automation =
        metadata
        |> Map.get("automation", %{})
        |> optional_put("summary", summary)
        |> Map.delete("createdCardIds")

      automation =
        if created == [], do: automation, else: Map.put(automation, "createdCardIds", created)

      artifacts = completion_artifacts(input["artifacts"], ids.artifacts, outer_now)

      notification = %{
        "id" => ids.notification,
        "createdAt" => outer_now,
        "sequence" => sequence,
        "kind" => "completed",
        "message" => cap(summary, 240) || "Workboard card completed."
      }

      metadata =
        metadata
        |> Map.put("automation", automation)
        |> Map.put("proof", proofs)
        |> append_workflow_comment(summary, ids.comment, outer_now)
        |> Map.put(
          "notifications",
          Enum.take(Map.get(metadata, "notifications", []) ++ [notification], -20)
        )

      metadata =
        if artifacts == [],
          do: metadata,
          else:
            Map.put(
              metadata,
              "artifacts",
              Enum.take(Map.get(metadata, "artifacts", []) ++ artifacts, -40)
            )

      preserve = proof_id || if(proof, do: proof["id"])
      metadata = trim_metadata(metadata, preserve, ids.notification)
      workflow_update(card, "done", metadata, ids.event, update_now, true)
    end)
  end

  def validate_decompose_parent(card, input) do
    try do
      supported_move_card!(card)
      assert_completion_identity!(card, input)
      :ok
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def decompose_child(parent, child, index) do
    workflow_result(fn ->
      unless json_map?(child), do: invalid("children must be objects")

      fields!(
        child,
        ~w(title notes agentId priority labels boardId tenant skills workspace maxRuntimeSeconds maxRetries idempotencyKey)
      )

      automation = get_in(parent, ["metadata", "automation"]) || %{}

      child
      |> Map.put("parents", [parent["id"]])
      |> Map.put("createdByCardId", parent["id"])
      |> Map.put("boardId", nullish(child["boardId"], automation["boardId"]))
      |> Map.put("tenant", nullish(child["tenant"], automation["tenant"]))
      |> Map.put(
        "idempotencyKey",
        nullish(
          child["idempotencyKey"],
          child_idempotency_key(automation["idempotencyKey"], index)
        )
      )
      |> then(&normalize_action("create", &1))
    end)
  end

  defp child_idempotency_key(nil, _index), do: nil

  defp child_idempotency_key(parent_key, index) do
    key = parent_key <> ":child:" <> Integer.to_string(index)
    if TextBudget.utf16_length(key) <= 160, do: key
  end

  def decompose_summary(input), do: workflow_result(fn -> bounded(input["summary"], 2000) end)

  def decompose_open(card, summary, created_ids, event_id, now) do
    workflow_result(fn ->
      supported_move_card!(card)
      metadata = Map.get(card, "metadata", %{})

      automation =
        metadata
        |> Map.get("automation", %{})
        |> optional_put("summary", summary)
        |> Map.put("createdCardIds", strings(created_ids, 120, 20, :reject))

      metadata = Map.put(metadata, "automation", automation)
      status = if card["status"] in ~w(triage backlog), do: "todo", else: card["status"]
      workflow_update(card, status, metadata, event_id, now, true)
    end)
  end

  def decomposed(card, expected_updated_at, event_id, now) do
    workflow_result(fn ->
      supported_move_card!(card)
      unless card["updatedAt"] === expected_updated_at, do: invalid("card update conflict")

      workflow_update(
        card,
        card["status"],
        Map.get(card, "metadata", %{}),
        event_id,
        now,
        false,
        %{"kind" => "decomposed"}
      )
    end)
  end

  def created_card_ids(input) do
    try do
      {:ok, strings(input["createdCardIds"], 120, 20, :reject)}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def child_ids(card), do: dependency_ids(card, "child")

  def owner_available(cards, target_id, owner_id, now) do
    if Enum.any?(cards, fn card ->
         card["id"] != target_id and consumes_owner_slot?(card, now) and
           slot_owner(card) == owner_id
       end),
       do:
         {:error, {:invalid_input, "Owner " <> owner_id <> " already has active Workboard work"}},
       else: :ok
  end

  defp consumes_owner_slot?(card, now) do
    metadata = Map.get(card, "metadata", %{})
    claim = metadata["claim"]
    execution = Map.get(card, "execution") || %{}

    not truthy?(metadata["archivedAt"]) and not reclaimable?(claim, now) and
      (card["status"] == "running" or (card["status"] != "done" and future_claim?(claim, now)) or
         (truthy?(execution["id"]) and execution["status"] == "running"))
  end

  defp slot_owner(card) do
    owner = get_in(card, ["metadata", "claim", "ownerId"])

    cond do
      truthy?(owner) -> owner
      truthy?(card["agentId"]) -> card["agentId"]
      true -> "workboard-dispatcher"
    end
  end

  defp future_claim?(nil, _), do: false

  defp future_claim?(claim, now) do
    expires = claim["expiresAt"]
    is_number(expires) and abs(expires) <= @maximum_date and expires > now
  end

  defp reclaimable?(nil, _), do: false

  defp reclaimable?(claim, now),
    do: truthy?(claim["expiresAt"]) and now - claim["expiresAt"] > 300_000

  defp truthy?(value), do: value not in [nil, false, 0, ""]
  defp add_duration(now, duration), do: min(@maximum_date, now + duration)

  defp assert_claim_identity!(claim, input) do
    token = optional_string(input["token"])
    owner = optional_string(input["ownerId"])

    if token && not secure_token_equal?(token, claim["token"]),
      do: invalid("claim token does not match")

    if is_nil(token) and not is_nil(owner) and owner != claim["ownerId"],
      do: invalid("claim owner does not match")
  end

  defp assert_completion_identity!(card, input) do
    claim = get_in(card, ["metadata", "claim"])

    if not is_nil(claim) and claim["ownerId"] != optional_string(input["ownerId"]) and
         not secure_token_equal?(optional_string(input["token"]), claim["token"]),
       do: invalid("card is claimed by " <> claim["ownerId"])
  end

  # Same optional UTF-8 and padded timing-safe comparison as safeEqualSecret.
  defp secure_token_equal?(provided, expected) when is_binary(provided) and is_binary(expected) do
    size = max(byte_size(provided), byte_size(expected))

    if size == 0 do
      true
    else
      padded_provided = provided <> :binary.copy(<<0>>, size - byte_size(provided))
      padded_expected = expected <> :binary.copy(<<0>>, size - byte_size(expected))

      :crypto.hash_equals(padded_provided, padded_expected) and
        byte_size(provided) == byte_size(expected)
    end
  end

  defp secure_token_equal?(_, _), do: false

  defp clear_diagnostics(metadata, kinds) do
    if Map.has_key?(metadata, "diagnostics"),
      do:
        Map.update!(
          metadata,
          "diagnostics",
          &Enum.reject(&1, fn entry -> entry["kind"] in kinds end)
        ),
      else: metadata
  end

  defp append_workflow_comment(metadata, nil, _id, _now), do: metadata

  defp append_workflow_comment(metadata, body, id, now),
    do:
      Map.put(
        metadata,
        "comments",
        Enum.take(
          Map.get(metadata, "comments", []) ++
            [%{"id" => id, "body" => body, "createdAt" => now}],
          -50
        )
      )

  defp completion_proof(input, id, now) when is_map(input) do
    compact(%{
      "id" => id,
      "createdAt" => now,
      "status" =>
        if(input["status"] in ~w(passed failed skipped unknown),
          do: input["status"],
          else: "unknown"
        ),
      "label" => bounded(input["label"], 160),
      "command" => bounded(input["command"], 1000),
      "url" => bounded(input["url"], 2000),
      "note" => bounded(input["note"], 2000)
    })
  end

  defp completion_proof(_, _, _), do: nil

  defp resolve_completion_proof(entries, proof, nil),
    do: Enum.take(entries ++ if(proof, do: [proof], else: []), -40)

  defp resolve_completion_proof(entries, proof, id) do
    index = Enum.find_index(entries, &(&1["id"] == id))
    if is_nil(index), do: invalid("proof not found: " <> id)
    pending = Enum.at(entries, index)
    completion = proof || pending

    if completion["status"] == "unknown",
      do: invalid("completion proof status must be passed, failed, or skipped")

    if Enum.any?(
         ~w(label command url note),
         &(Map.has_key?(completion, &1) and completion[&1] != pending[&1])
       ),
       do: invalid("completion proof does not match pending proof: " <> id)

    if pending["status"] != "unknown" and pending["status"] != completion["status"],
      do: invalid("completion proof status does not match existing proof: " <> id)

    entries =
      if pending["status"] == "unknown",
        do: List.replace_at(entries, index, Map.put(pending, "status", completion["status"])),
        else: entries

    Enum.take(entries, -40)
  end

  defp completion_artifacts(input, ids, now) when is_list(input) do
    input
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      entry = if is_map(entry), do: entry, else: %{}
      url = bounded(entry["url"], 2000)
      path = bounded(entry["path"], 2000)
      label = bounded(entry["label"], 160)
      mime = bounded(entry["mimeType"], 160)

      if url || path do
        [
          compact(%{
            "id" => optional_string(entry["id"]) || Enum.at(ids, index),
            "createdAt" => now,
            "label" => label,
            "url" => url,
            "path" => path,
            "mimeType" => mime
          })
        ]
      else
        []
      end
    end)
    |> Enum.take(-40)
  end

  defp completion_artifacts(_, _, _), do: []

  defp workflow_result(operation) do
    try do
      {:ok, operation.()}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  defp workflow_update(card, status, metadata, event_id, now, enforce_holds, forced_event \\ nil) do
    updated = max(now, card["updatedAt"] + 1)
    scheduled = get_in(metadata, ["automation", "scheduledAt"])

    if enforce_holds and status in ~w(ready running review) and
         ((truthy?(scheduled) and scheduled > updated) or
            (card["status"] == "scheduled" and not truthy?(scheduled))),
       do: invalid("card is scheduled for later")

    next =
      card
      |> Map.put("status", status)
      |> Map.put("metadata", trim_metadata(metadata))
      |> Map.put("updatedAt", updated)

    next =
      if status == "running",
        do: Map.put(next, "startedAt", card["startedAt"] || updated),
        else: next

    next =
      if status == "done",
        do: Map.put(next, "completedAt", card["completedAt"] || updated),
        else: Map.delete(next, "completedAt")

    event =
      (forced_event || workflow_event(card, next))
      |> Map.merge(%{"id" => event_id, "at" => updated})

    Map.put(next, "events", Enum.take(Map.get(card, "events", []) ++ [event], -50))
  end

  defp workflow_event(existing, next) do
    cond do
      existing["status"] != next["status"] or existing["position"] != next["position"] ->
        %{"kind" => "moved", "fromStatus" => existing["status"], "toStatus" => next["status"]}

      get_in(existing, ["metadata", "claim", "token"]) !=
          get_in(next, ["metadata", "claim", "token"]) ->
        %{"kind" => "claimed"}

      get_in(existing, ["metadata", "claim", "lastHeartbeatAt"]) !=
          get_in(next, ["metadata", "claim", "lastHeartbeatAt"]) ->
        %{"kind" => "heartbeat"}

      true ->
        changed =
          Enum.find(
            [
              {"comments", "comment_added"},
              {"links", "link_added"},
              {"proof", "proof_added"},
              {"artifacts", "artifact_added"}
            ],
            fn {key, _kind} -> entries_changed?(existing, next, key) end
          )

        cond do
          changed ->
            %{"kind" => elem(changed, 1)}

          entries_changed?(existing, next, "attachments") ->
            %{
              "kind" =>
                if(
                  length(get_in(next, ["metadata", "attachments"]) || []) >
                    length(get_in(existing, ["metadata", "attachments"]) || []),
                  do: "attachment_added",
                  else: "edited"
                )
            }

          length(get_in(existing, ["metadata", "diagnostics"]) || []) !=
              length(get_in(next, ["metadata", "diagnostics"]) || []) ->
            %{"kind" => "diagnostic"}

          entries_changed?(existing, next, "notifications") ->
            %{"kind" => "notification"}

          true ->
            %{"kind" => "edited"}
        end
    end
  end

  defp entries_changed?(existing, next, key) do
    previous = get_in(existing, ["metadata", key]) || []
    current = get_in(next, ["metadata", key]) || []
    latest = List.last(current)

    length(previous) != length(current) or
      (latest != nil and truthy?(latest["id"]) and
         latest["id"] != (List.last(previous) || %{})["id"])
  end

  def board_payload(%{"archived" => archived} = input, previous, now) do
    board = board_payload(Map.delete(input, "archived"), previous, now)

    if archived === false,
      do: Map.delete(board, "archivedAt"),
      else: Map.put(board, "archivedAt", now)
  end

  def board_payload(input, previous, now) do
    previous = previous || %{"id" => input["id"], "createdAt" => now}
    previous |> Map.put_new("createdAt", now) |> Map.merge(input) |> Map.put("updatedAt", now)
  end

  def creation_status(input, now) do
    scheduled_at = input["automation"]["scheduledAt"]

    if scheduled_at && scheduled_at > now && input["status"] != "blocked",
      do: "scheduled",
      else: input["status"]
  end

  def card(input, id, event_id, position, now) do
    status = input["status"]

    compact(%{
      "id" => id,
      "title" => input["title"],
      "status" => status,
      "priority" => input["priority"],
      "labels" => input["labels"],
      "position" => position,
      "createdAt" => now,
      "updatedAt" => now,
      "notes" => input["notes"],
      "agentId" => input["agentId"],
      "metadata" => %{"automation" => input["automation"]},
      "events" => [%{"id" => event_id, "kind" => "created", "at" => now, "toStatus" => status}],
      "startedAt" => if(status == "running", do: now),
      "completedAt" => if(status == "done", do: now)
    })
  end

  def comment(card, body, comment_id, event_id, now) do
    metadata = Map.get(card, "metadata", %{})
    comment = %{"id" => comment_id, "body" => body, "createdAt" => now}

    metadata =
      metadata
      |> Map.put("comments", Enum.take(Map.get(metadata, "comments", []) ++ [comment], -50))
      |> trim_metadata()

    updated = max(now, card["updatedAt"] + 1)
    event = %{"id" => event_id, "kind" => "comment_added", "at" => updated}

    card
    |> Map.put("metadata", metadata)
    |> Map.put("updatedAt", updated)
    |> Map.put("events", Enum.take(Map.get(card, "events", []) ++ [event], -50))
  end

  def move(card, input, event_id, now), do: move_card(card, input, event_id, now, true)

  defp move_card(card, input, event_id, now, enforce_holds) do
    try do
      supported_move_card!(card)
      status = enum(input["status"], @statuses, card["status"])

      updated = max(now, card["updatedAt"] + 1)
      scheduled_at = get_in(card, ["metadata", "automation", "scheduledAt"])

      # Source compares schedule holds with the update's monotonic card clock.
      if enforce_holds and status in ~w(ready running review) and
           ((scheduled_at && scheduled_at > updated) ||
              (card["status"] == "scheduled" and is_nil(scheduled_at))),
         do: invalid("card is scheduled for later")

      position =
        if Map.has_key?(input, "position") do
          value = if is_number(input["position"]), do: input["position"], else: card["position"]
          max(0, floor(value))
        else
          card["position"]
        end

      event =
        if status != card["status"] or position != card["position"] do
          %{
            "id" => event_id,
            "at" => updated,
            "kind" => "moved",
            "fromStatus" => card["status"],
            "toStatus" => status
          }
        else
          %{"id" => event_id, "at" => updated, "kind" => "edited"}
        end

      next =
        card
        |> Map.put("status", status)
        |> Map.put("position", position)
        |> Map.put("updatedAt", updated)
        |> Map.put("events", Enum.take(Map.get(card, "events", []) ++ [event], -50))

      next =
        if status == "running",
          do: Map.put(next, "startedAt", card["startedAt"] || updated),
          else: next

      next =
        if status == "done",
          do: Map.put(next, "completedAt", card["completedAt"] || updated),
          else: Map.delete(next, "completedAt")

      {:ok, next}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def promote(card, input, comment_id, event_id, comment_now, update_now) do
    try do
      supported_move_card!(card)
      unless card["status"] == "todo", do: invalid("only todo cards can be promoted")

      metadata = Map.get(card, "metadata", %{}) |> Map.delete("stale")

      metadata =
        if Map.has_key?(metadata, "diagnostics") do
          Map.update!(metadata, "diagnostics", fn entries ->
            Enum.reject(entries, &(&1["kind"] in ~w(stranded_ready blocked_too_long)))
          end)
        else
          metadata
        end

      metadata =
        if input["reason"] do
          comment = %{"id" => comment_id, "body" => input["reason"], "createdAt" => comment_now}

          Map.put(
            metadata,
            "comments",
            Enum.take(Map.get(metadata, "comments", []) ++ [comment], -50)
          )
        else
          metadata
        end

      move_card(
        Map.put(card, "metadata", trim_metadata(metadata)),
        %{"status" => "ready"},
        event_id,
        update_now,
        input["force"] !== true
      )
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def proof(card, input, proof_id, artifact_id, event_id, created_at, update_now) do
    try do
      supported_move_card!(card)

      status =
        if input["status"] in ~w(passed failed skipped unknown),
          do: input["status"],
          else: "unknown"

      label = bounded(input["label"], 160)
      url = bounded(input["url"], 2000)
      path = bounded(input["artifactPath"], 2000)

      proof =
        compact(%{
          "id" => proof_id,
          "status" => status,
          "createdAt" => created_at,
          "label" => label,
          "command" => bounded(input["command"], 1000),
          "url" => url,
          "note" => bounded(input["note"], 2000)
        })

      metadata = Map.get(card, "metadata", %{})

      metadata =
        if Map.has_key?(metadata, "diagnostics"),
          do:
            Map.update!(
              metadata,
              "diagnostics",
              &Enum.reject(&1, fn entry -> entry["kind"] == "missing_proof" end)
            ),
          else: metadata

      metadata =
        Map.put(metadata, "proof", Enum.take(Map.get(metadata, "proof", []) ++ [proof], -40))

      metadata =
        if url || path do
          artifact =
            compact(%{
              "id" => artifact_id,
              "createdAt" => created_at,
              "label" => label,
              "url" => url,
              "path" => path
            })

          Map.put(
            metadata,
            "artifacts",
            Enum.take(Map.get(metadata, "artifacts", []) ++ [artifact], -40)
          )
        else
          metadata
        end

      updated_at = max(update_now, card["updatedAt"] + 1)
      event = %{"id" => event_id, "kind" => "proof_added", "at" => updated_at}

      next =
        card
        |> Map.put("metadata", trim_metadata(metadata, proof_id))
        |> Map.put("updatedAt", updated_at)
        |> Map.put("events", Enum.take(Map.get(card, "events", []) ++ [event], -50))

      next =
        if card["status"] == "running", do: Map.put_new(next, "startedAt", updated_at), else: next

      next =
        if card["status"] == "done",
          do: Map.put_new(next, "completedAt", updated_at),
          else: Map.delete(next, "completedAt")

      {:ok, next}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def attachment_add(card, input, attachment_id, event_id, created_at, update_now) do
    try do
      supported_move_card!(card)
      file_name = bounded(input["fileName"], 240)
      unless file_name, do: invalid("attachment fileName is required")
      content = input["contentBase64"]

      unless is_binary(content) and byte_size(content) <= div(262_144 + 2, 3) * 4,
        do: invalid("attachment contentBase64 must be canonical base64")

      bytes =
        case Base.decode64(content) do
          {:ok, bytes} -> bytes
          :error -> invalid("attachment contentBase64 must be canonical base64")
        end

      unless Base.encode64(bytes) == content,
        do: invalid("attachment contentBase64 must be canonical base64")

      unless byte_size(bytes) > 0 and byte_size(bytes) <= 262_144,
        do: invalid("attachment must be between 1 and 262144 bytes")

      attachment =
        compact(%{
          "id" => attachment_id,
          "cardId" => card["id"],
          "createdAt" => created_at,
          "fileName" => file_name,
          "byteSize" => byte_size(bytes),
          "mimeType" => bounded(input["mimeType"], 160),
          "note" => bounded(input["note"], 400)
        })

      metadata = Map.get(card, "metadata", %{})

      metadata =
        if Map.has_key?(metadata, "diagnostics"),
          do:
            Map.update!(
              metadata,
              "diagnostics",
              &Enum.reject(&1, fn d -> d["kind"] == "missing_proof" end)
            ),
          else: metadata

      metadata =
        metadata
        |> Map.put(
          "attachments",
          Enum.take(Map.get(metadata, "attachments", []) ++ [attachment], -20)
        )
        |> trim_metadata()

      unless Enum.any?(Map.get(metadata, "attachments", []), &(&1["id"] == attachment_id)),
        do: invalid("attachment metadata was trimmed before it could be indexed")

      kind =
        if length(Map.get(metadata, "attachments", [])) >
             length(get_in(card, ["metadata", "attachments"]) || []),
           do: "attachment_added",
           else: "edited"

      next = attachment_update(card, metadata, kind, event_id, update_now)
      {:ok, next, %{"version" => 1, "attachment" => attachment, "contentBase64" => content}}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def attachment_delete(card, attachment_id, event_id, update_now) do
    try do
      supported_move_card!(card)
      metadata = Map.get(card, "metadata", %{})
      attachments = Map.get(metadata, "attachments", [])

      unless Enum.any?(attachments, &(&1["id"] == attachment_id)),
        do: invalid("attachment not found")

      metadata =
        metadata
        |> Map.put("attachments", Enum.reject(attachments, &(&1["id"] == attachment_id)))
        |> trim_metadata()

      {:ok, attachment_update(card, metadata, "edited", event_id, update_now)}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  defp attachment_update(card, metadata, kind, event_id, update_now) do
    updated_at = max(update_now, card["updatedAt"] + 1)
    event = %{"id" => event_id, "kind" => kind, "at" => updated_at}

    next =
      card
      |> Map.put("metadata", metadata)
      |> Map.put("updatedAt", updated_at)
      |> Map.put("events", Enum.take(Map.get(card, "events", []) ++ [event], -50))

    next =
      if card["status"] == "running", do: Map.put_new(next, "startedAt", updated_at), else: next

    if card["status"] == "done",
      do: Map.put_new(next, "completedAt", updated_at),
      else: Map.delete(next, "completedAt")
  end

  def specify(card, input, comment_id, event_id, event_now, update_now) do
    try do
      supported_move_card!(card)

      unless card["status"] in ~w(triage backlog todo),
        do: invalid("only triage, backlog, or todo cards can be specified")

      summary = bounded(input["summary"], 2000)
      metadata = Map.get(card, "metadata", %{})
      automation = Map.get(metadata, "automation", %{})
      automation = if summary, do: Map.put(automation, "summary", summary), else: automation

      automation =
        Enum.reduce(
          ~w(tenant boardId skills workspace maxRuntimeSeconds maxRetries),
          automation,
          fn key, current ->
            if Map.has_key?(input, key) do
              value =
                case key do
                  "tenant" -> bounded(input[key], 80) || current[key]
                  "boardId" -> optional_board_slug(input[key]) || current[key]
                  "skills" -> strings(input[key], 80, 20, :reject)
                  "workspace" -> workspace_patch(input[key], current[key])
                  _ -> positive_integer(input[key])
                end

              if value in [nil, []],
                do: Map.delete(current, key),
                else: Map.put(current, key, value)
            else
              current
            end
          end
        )

      metadata = Map.put(metadata, "automation", automation)

      metadata =
        if summary do
          comment = %{"id" => comment_id, "body" => summary, "createdAt" => event_now}

          Map.put(
            metadata,
            "comments",
            Enum.take(Map.get(metadata, "comments", []) ++ [comment], -50)
          )
        else
          metadata
        end

      next =
        Enum.reduce(~w(title notes agentId labels), card, fn key, current ->
          if Map.has_key?(input, key) do
            value =
              case key do
                "title" -> bounded(input[key], 180) || invalid("title is required")
                "notes" -> bounded(input[key], 4000)
                "agentId" -> optional_string(input[key])
                "labels" -> strings(input[key], 40, 12, :cap)
              end

            if is_nil(value), do: Map.delete(current, key), else: Map.put(current, key, value)
          else
            current
          end
        end)

      event = %{"id" => event_id, "kind" => "specified", "at" => event_now}

      next =
        next
        |> Map.put("status", "todo")
        |> Map.put("priority", enum(input["priority"], @priorities, card["priority"]))
        |> Map.put("metadata", trim_metadata(metadata))
        |> Map.put("updatedAt", max(update_now, card["updatedAt"] + 1))
        |> Map.delete("completedAt")
        |> Map.put("events", Enum.take(Map.get(card, "events", []) ++ [event], -50))

      {:ok, next}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  defp workspace_patch(value, fallback) when is_map(value) and not is_struct(value) do
    fields!(value, ~w(kind path branch))
    fallback = fallback || %{}
    kind = if value["kind"] in ~w(scratch dir worktree), do: value["kind"], else: fallback["kind"]
    path = bounded(value["path"], 2000) || fallback["path"]
    previous_branch = if path == fallback["path"], do: fallback["branch"]
    branch = bounded(value["branch"], 160) || previous_branch
    workspace(compact(%{"kind" => kind, "path" => path, "branch" => branch}))
  end

  defp workspace_patch(_, fallback), do: fallback

  defp supported_move_card!(card) do
    fields!(card, @move_card_keys)
    metadata = Map.get(card, "metadata", %{})
    unless is_map(metadata), do: invalid("unsupported move metadata")

    fields!(
      metadata,
      ~w(automation comments proof artifacts diagnostics attachments links stale archivedAt claim notifications failureCount)
    )

    automation = Map.get(metadata, "automation", %{})
    unless is_map(automation), do: invalid("unsupported move automation")

    fields!(
      automation,
      ~w(boardId tenant idempotencyKey skills workspace maxRuntimeSeconds maxRetries summary createdByCardId scheduledAt createdCardIds)
    )
  end

  # Source: store-core.ts linkCardsDirect/dependencyTargetStatus and
  # store-normalizers.ts appendLinkPreservingDependencies (488631c).
  def parent_ids(card), do: dependency_ids(card, "parent")

  defp dependency_ids(card, type) do
    card |> projected_dependency_ids(type) |> Enum.uniq()
  end

  defp projected_dependency_ids(card, type) do
    (get_in(card, ["metadata", "links"]) || [])
    |> Enum.filter(&(&1["type"] == type and &1["targetCardId"] not in [nil, ""]))
    |> Enum.map(& &1["targetCardId"])
  end

  defp dependency_projection(projection, card) do
    if Map.has_key?(Map.get(card, "metadata", %{}), "links") do
      projection
      |> Map.put("parents", projected_dependency_ids(card, "parent"))
      |> Map.put("children", projected_dependency_ids(card, "child"))
    else
      projection
    end
  end

  def validate_parent(card) do
    try do
      supported_move_card!(card)
      :ok
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def validate_link(parent, child, parents_done, cycle, allow_status_only \\ false) do
    try do
      if parent["id"] == child["id"], do: invalid("parent and child cards must differ")
      supported_move_card!(parent)
      supported_move_card!(child)

      if child["status"] in ~w(done blocked) and not parents_done,
        do: invalid("terminal child cards cannot gain incomplete parent dependencies")

      # Decomposition alone may link status-only active key hits. A real claim
      # remains active; execution and attempts remain outside supported cards.
      if (allow_status_only and truthy?(get_in(child, ["metadata", "claim"]))) or
           (not allow_status_only and child["status"] in ~w(running review)),
         do: invalid("active child cards cannot gain parent dependencies")

      if cycle, do: invalid("dependency link would create a cycle")
      :ok
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def dependency_metadata(card, target_id, type, link_id, event_id, created_at, now) do
    try do
      supported_move_card!(card)
      metadata = Map.get(card, "metadata", %{})
      links = Map.get(metadata, "links", [])

      next_links =
        if Enum.any?(links, &(&1["type"] == type and &1["targetCardId"] == target_id)) do
          links
        else
          next =
            links ++
              [
                %{
                  "id" => link_id,
                  "type" => type,
                  "targetCardId" => target_id,
                  "createdAt" => created_at
                }
              ]

          if length(next) <= 50 do
            next
          else
            index = Enum.find_index(next, &(&1["type"] not in ~w(parent child)))
            if is_nil(index) or index == length(next) - 1, do: invalid("card link limit reached")
            List.delete_at(next, index)
          end
        end

      metadata = metadata |> Map.put("links", next_links) |> trim_metadata()
      kind = if metadata["links"] != links, do: "link_added", else: "edited"
      {:ok, attachment_update(card, metadata, kind, event_id, now)}
    catch
      {:invalid_workboard_input, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  def dependency_status(card, parents_done, now) do
    scheduled_at = get_in(card, ["metadata", "automation", "scheduledAt"])

    cond do
      card["status"] == "scheduled" and is_nil(scheduled_at) ->
        "scheduled"

      card["status"] not in ~w(backlog triage todo scheduled ready) ->
        card["status"]

      scheduled_at && scheduled_at > now ->
        "scheduled"

      parent_ids(card) == [] ->
        if(card["status"] == "scheduled", do: "ready", else: card["status"])

      parents_done ->
        "ready"

      true ->
        "todo"
    end
  end

  defp scheduled_timestamp(value) when is_number(value) do
    case max(0, floor(value)) do
      0 -> nil
      timestamp -> timestamp
    end
  end

  defp scheduled_timestamp(_), do: nil

  defp create_status(value, parents) do
    status = enum(value, @statuses, "todo")
    if parents != [] and status in ~w(running review), do: "todo", else: status
  end

  defp parent_strings(value) do
    entries =
      cond do
        is_nil(value) -> []
        is_binary(value) -> String.split(value, ",")
        is_list(value) -> value
        true -> invalid("parents must be an array or comma-separated string")
      end

    Enum.reduce_while(entries, [], fn entry, values ->
      unless is_binary(entry), do: invalid("parents must contain only strings")
      normalized = optional_string(entry)

      if is_nil(normalized) or normalized in values do
        {:cont, values}
      else
        normalized = bounded(normalized, 120)
        next = values ++ [normalized]
        if length(next) >= 20, do: {:halt, next}, else: {:cont, next}
      end
    end)
  end

  def summarize(card) do
    automation = get_in(card, ["metadata", "automation"]) || %{}

    card
    |> Map.take(~w(id title status priority agentId updatedAt))
    |> Map.put("boardId", Map.get(automation, "boardId", "default"))
    |> optional_put("tenant", automation["tenant"])
    |> optional_put("diagnostics", get_in(card, ["metadata", "diagnostics"]))
    |> optional_put("archivedAt", get_in(card, ["metadata", "archivedAt"]))
    |> dependency_projection(card)
  end

  def projection(card), do: Map.merge(summarize(card), Map.take(card, ~w(position createdAt)))
  def public_projection(card), do: Map.drop(card, ~w(position createdAt))

  def sort(cards) do
    cards
    |> Enum.with_index()
    |> Enum.sort_by(fn {card, index} ->
      {Enum.find_index(@statuses, &(&1 == card["status"])), card["position"], card["createdAt"],
       index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  def filter(cards, input) do
    Enum.filter(cards, fn card ->
      card["archivedAt"] in [nil, false, 0, ""] and
        Enum.all?(~w(status agentId tenant boardId), fn key ->
          value = input[key]
          is_nil(value) or value == "" or card[key] == value
        end)
    end)
  end

  def stats(cards, board_id, now) do
    initial = %{
      "id" => board_id || "all",
      "total" => 0,
      "active" => 0,
      "archived" => 0,
      "byStatus" => %{},
      "byAgent" => %{}
    }

    {result, oldest_ready, updated_at} =
      cards
      |> Enum.filter(&(is_nil(board_id) or &1["boardId"] == board_id))
      |> Enum.reduce({initial, nil, 0}, fn card, {result, oldest, updated} ->
        archived = card["archivedAt"] not in [nil, false, 0, ""]
        agent = if card["agentId"] in [nil, ""], do: "(default)", else: card["agentId"]

        oldest =
          if card["status"] == "ready" and not archived do
            if is_nil(oldest), do: card["updatedAt"], else: min(oldest, card["updatedAt"])
          else
            oldest
          end

        result = %{
          result
          | "total" => result["total"] + 1,
            "active" => result["active"] + if(archived, do: 0, else: 1),
            "archived" => result["archived"] + if(archived, do: 1, else: 0),
            "byStatus" => Map.update(result["byStatus"], card["status"], 1, &(&1 + 1)),
            "byAgent" => Map.update(result["byAgent"], agent, 1, &(&1 + 1))
        }

        {result, oldest, max(updated, card["updatedAt"])}
      end)

    result
    |> optional_put("updatedAt", if(updated_at != 0, do: updated_at))
    |> optional_put(
      "oldestReadyAgeMs",
      if(oldest_ready not in [nil, 0], do: max(0, now - oldest_ready))
    )
  end

  def board_summary(board, cards) do
    board_cards = Enum.filter(cards, &(&1["boardId"] == board["id"]))
    archived = Enum.count(board_cards, &(&1["archivedAt"] not in [nil, false, 0, ""]))

    board
    |> Map.delete("createdAt")
    |> Map.merge(%{
      "total" => length(board_cards),
      "active" => length(board_cards) - archived,
      "archived" => archived,
      "byStatus" => Enum.frequencies_by(board_cards, & &1["status"]),
      "updatedAt" =>
        Enum.reduce(board_cards, Map.get(board, "updatedAt", 0), &max(&1["updatedAt"], &2))
    })
  end

  # Pinned source/current-host localeCompare over the accepted lowercase ASCII
  # slug alphabet only: underscore, hyphen, dot, digits, letters. This does not
  # implement locale collation for arbitrary Unicode names.
  def sort_boards(boards) do
    Enum.sort_by(boards, fn board ->
      weights = for <<point <- board["id"]>>, do: slug_weight(point)
      {if(board["id"] == "default", do: 0, else: 1), weights}
    end)
  end

  defp slug_weight(?_), do: 0
  defp slug_weight(?-), do: 1
  defp slug_weight(?.), do: 2
  defp slug_weight(point), do: point

  def worker_context(card, recent_done, now, parents \\ []) do
    automation = get_in(card, ["metadata", "automation"]) || %{}
    agent = Map.get(card, "agentId", "(default)")

    lines = [
      "# Workboard card #{card["id"]}",
      "Title: #{card["title"]}",
      "Status: #{card["status"]}",
      "Priority: #{card["priority"]}",
      "Board: #{Map.get(automation, "boardId", "default")}",
      "Agent: #{agent}"
    ]

    lines = if card["notes"], do: lines ++ ["", "## Notes", cap(card["notes"], 4000)], else: lines
    comments = Enum.take(get_in(card, ["metadata", "comments"]) || [], -12)
    lines = section(lines, "Recent comments", Enum.map(comments, &("- " <> cap(&1["body"], 400))))

    proofs =
      (get_in(card, ["metadata", "proof"]) || [])
      |> Enum.take(-8)
      |> Enum.map(fn entry ->
        detail = entry["label"] || entry["command"] || entry["url"] || entry["note"]
        "- #{entry["status"]}: #{cap(detail, 400) || "undefined"}"
      end)

    lines = section(lines, "Proof", proofs)

    artifacts =
      (get_in(card, ["metadata", "artifacts"]) || [])
      |> Enum.take(-8)
      |> Enum.map(fn entry ->
        "- " <> cap(entry["label"] || entry["url"] || entry["path"], 400)
      end)

    lines = section(lines, "Artifacts", artifacts)

    attachments =
      (get_in(card, ["metadata", "attachments"]) || [])
      |> Enum.take(-8)
      |> Enum.map(fn entry ->
        detail =
          [entry["fileName"], "#{entry["byteSize"]} bytes", entry["mimeType"], entry["note"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        "- " <> cap(detail, 500)
      end)

    lines = section(lines, "Attachments", attachments)

    links =
      (get_in(card, ["metadata", "links"]) || [])
      |> Enum.take(-8)
      |> Enum.map(fn link ->
        "- #{link["type"]}: #{link["title"] || link["url"] || link["targetCardId"] || ""}"
      end)

    lines = section(lines, "Links", links)

    parent_results =
      parents
      |> Enum.filter(&(&1["status"] == "done"))
      |> Enum.take(-6)
      |> Enum.map(fn parent ->
        "- #{parent["id"]} #{parent["title"]}: #{cap(result_summary(parent), 500) || "done"}"
      end)

    lines = section(lines, "Parent results", parent_results)

    recent =
      Enum.map(recent_done, fn entry ->
        "- #{entry["id"]} #{entry["title"]}: #{cap(result_summary(entry), 300) || "done"}"
      end)

    lines = section(lines, "Recent done work by #{card["agentId"]}", recent)
    lines = if map_size(automation) == 0, do: lines, else: lines ++ ["", "## Automation"]
    lines = append_line(lines, automation["tenant"], "Tenant: ")
    lines = append_line(lines, automation["boardId"], "Board: ")

    lines =
      case automation["skills"] do
        [_ | _] = skills -> lines ++ ["Skills: " <> Enum.join(skills, ", ")]
        _ -> lines
      end

    lines =
      case automation["workspace"] do
        %{"kind" => kind} = workspace ->
          lines ++
            [
              "Workspace: " <>
                kind <> if(workspace["path"], do: " " <> workspace["path"], else: "")
            ]

        _ ->
          lines
      end

    lines = append_line(lines, cap(automation["summary"], 400), "Summary: ")
    lines = section(lines, "Active diagnostics", diagnostics(card, now))
    Enum.join(lines, "\n")
  end

  defp result_summary(card) do
    get_in(card, ["metadata", "automation", "summary"]) ||
      Enum.find_value(Enum.reverse(get_in(card, ["metadata", "comments"]) || []), fn comment ->
        if optional_string(comment["body"]), do: comment["body"]
      end) ||
      Enum.find_value(Enum.reverse(get_in(card, ["metadata", "proof"]) || []), fn proof ->
        if optional_string(proof["note"]), do: proof["note"]
      end)
  end

  defp diagnostics(card, now) do
    []
    |> maybe_diagnostic(
      card["status"] in ~w(todo backlog ready) and not is_nil(card["agentId"]) and
        now - card["updatedAt"] > 3_600_000,
      "- warning: Assigned card is waiting"
    )
    |> maybe_diagnostic(
      card["status"] == "running" and now - card["updatedAt"] > 1_200_000,
      "- error: Running card has no recent heartbeat"
    )
    |> maybe_diagnostic(
      card["status"] == "blocked" and now - card["updatedAt"] > 86_400_000,
      "- warning: Blocked card needs attention"
    )
    |> maybe_diagnostic(
      card["status"] == "done" and
        not Enum.any?(
          ~w(proof artifacts attachments),
          &(get_in(card, ["metadata", &1]) not in [nil, []])
        ),
      "- warning: Done card has no proof"
    )
  end

  defp maybe_diagnostic(lines, true, line), do: lines ++ [line]
  defp maybe_diagnostic(lines, false, _), do: lines
  defp section(lines, _, []), do: lines
  defp section(lines, heading, entries), do: lines ++ ["", "## " <> heading] ++ entries
  defp append_line(lines, nil, _), do: lines
  defp append_line(lines, value, prefix), do: lines ++ [prefix <> value]

  defp cap(nil, _), do: nil

  defp cap(text, limit) do
    if TextBudget.utf16_length(text) <= limit,
      do: text,
      else: TextBudget.utf16_prefix(text, limit - 1) <> "…"
  end

  defp trim_metadata(metadata, preserve_proof_id \\ nil, preserve_notification_id \\ nil) do
    metadata =
      Map.reject(metadata, fn {key, value} ->
        value == [] or (key == "failureCount" and value == 0)
      end)

    if byte_size(Jason.encode!(metadata)) > 24 * 1024 do
      removable =
        Enum.find_value(
          ~w(diagnostics notifications proof artifacts attachments links comments),
          fn key ->
            entries = Map.get(metadata, key, [])

            index =
              cond do
                key == "proof" ->
                  Enum.find_index(entries, &(&1["id"] != preserve_proof_id))

                key == "notifications" ->
                  Enum.find_index(entries, &(&1["id"] != preserve_notification_id))

                key == "links" ->
                  Enum.find_index(entries, &(&1["type"] not in ~w(parent child)))

                entries != [] ->
                  0

                true ->
                  nil
              end

            if is_integer(index), do: {key, index}
          end
        )

      case removable do
        {key, index} ->
          trim_metadata(
            Map.update!(metadata, key, &List.delete_at(&1, index)),
            preserve_proof_id,
            preserve_notification_id
          )

        nil ->
          cond do
            preserve_proof_id ->
              invalid("card metadata cannot retain proof: " <> preserve_proof_id)

            preserve_notification_id ->
              invalid("card metadata cannot retain notification: " <> preserve_notification_id)

            true ->
              metadata
          end
      end
    else
      metadata
    end
  end

  defp workspace(value) when is_map(value) and not is_struct(value) do
    fields!(value, ~w(kind path branch))
    kind = value["kind"]

    unless kind in ~w(scratch dir worktree),
      do: invalid("workspace kind must be scratch, dir, or worktree")

    path = bounded(value["path"], 2000)

    if kind == "dir" and (is_nil(path) or not absolute_path?(path)),
      do: invalid("dir workspace path must be absolute")

    compact(%{"kind" => kind, "path" => path, "branch" => bounded(value["branch"], 160)})
  end

  defp workspace(_), do: nil

  defp absolute_path?(path),
    do:
      String.starts_with?(path, "/") or Regex.match?(~r/\A[A-Za-z]:[\\\/]/, path) or
        Regex.match?(~r/\A\\\\[^\\]+\\[^\\]+/, path)

  defp positive_integer(value) when value in [nil, ""], do: nil
  defp positive_integer(value) when is_number(value), do: max(1, trunc(value))
  defp positive_integer(_), do: invalid("runtime and retry hints must be numbers")

  defp strings(value, max_length, maximum, mode) do
    entries =
      cond do
        is_nil(value) -> []
        is_binary(value) -> String.split(value, ",")
        is_list(value) -> value
        true -> invalid("string list must be an array or comma-separated string")
      end

    Enum.reduce_while(entries, [], fn entry, values ->
      if mode == :reject and not is_binary(entry),
        do: invalid("string list entries must be strings")

      normalized = bounded(entry, max_length)

      next =
        if is_nil(normalized) or normalized in values, do: values, else: values ++ [normalized]

      cond do
        mode == :cap and length(next) >= maximum -> {:halt, next}
        length(next) > maximum -> invalid("too many string list entries")
        true -> {:cont, next}
      end
    end)
  end

  defp enum(value, allowed, fallback) do
    cond do
      value in allowed -> value
      is_nil(optional_string(value)) -> fallback
      true -> invalid("invalid status or priority")
    end
  end

  defp optional_board_slug(value) do
    if optional_string(value), do: board_slug(value)
  end

  defp board_slug(value) do
    slug = bounded(value, 80)
    unless slug, do: invalid("explicit board id is required")
    slug = String.downcase(slug)
    unless Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,79}\z/, slug), do: invalid("invalid board id")
    slug
  end

  defp card_id(value) do
    id = optional_string(value)

    unless is_binary(id) and match?({:ok, ^id}, Ecto.UUID.cast(id)),
      do: invalid("card id must be a UUID")

    id
  end

  defp bounded(value, maximum) do
    text = optional_string(value)
    if text && TextBudget.utf16_length(text) > maximum, do: invalid("text exceeds source length")
    text
  end

  defp optional_string(value) when is_binary(value) do
    case Regex.replace(@js_trim, value, "") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_), do: nil

  defp fields!(map, allowed) do
    if Map.keys(map) -- allowed != [], do: invalid("unsupported fields")
  end

  defp optional_put(map, _, nil), do: map
  defp optional_put(map, key, value), do: Map.put(map, key, value)
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp invalid(reason), do: throw({:invalid_workboard_input, reason})

  def json_map?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, value} ->
        is_binary(key) and String.valid?(key) and json?(value)
      end)

  def json_map?(_), do: false
  defp json?(value) when is_map(value), do: json_map?(value)
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)
end
