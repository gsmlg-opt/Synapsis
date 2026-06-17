# Mid-turn input queue and advisory steer

- **Date:** 2026-06-17
- **Status:** Approved design, pending implementation plan
- **Scope:** Change session input behavior so users can submit normal messages
  while an agent is running, and can explicitly send advisory steering input for
  the current turn.

## 1. Goal

Replace the current "reject mid-turn input" behavior with two explicit paths:

1. **Send** while the agent is running queues a normal user prompt for the next
   turn.
2. **Steer** while the agent is running records advisory context for the next
   LLM call inside the current turn, without cancelling in-flight work.

The feature should make the chat input usable during long agent runs without
mutating provider or tool state unpredictably.

## 2. Motivation

The current ADR-0006 policy rejects prompts while the session worker is not
idle. That keeps the graph simple, but it makes the UI feel stuck during long
provider streams and tool-heavy turns. Users should be able to type ahead, and
they should also have a separate way to influence the active turn when the agent
is about to make another model call.

The important distinction is intent:

- Normal **Send** means "do this after you finish what you are doing."
- Explicit **Steer** means "use this as guidance the next time you think in this
  active turn."

Conflating those two behaviors would create surprising context changes, so they
remain separate API and UI actions.

## 3. Decisions

| Decision | Choice |
|----------|--------|
| Normal Send while idle | Existing behavior: append user message and start turn |
| Normal Send while running | Persist a pending queue item, return success |
| Queue ordering | FIFO |
| Queue promotion | Promote one queued prompt when the graph returns to `:receive` |
| Queue batching | No batching in v1 |
| Queue durability | Store pending inputs outside the transcript until promotion |
| Steer behavior | Advisory only; never cancels streams, tools, or approvals |
| Steer injection point | Next `BuildPrompt`/LLM request in the active turn |
| Steer if no later LLM call occurs | Convert to the next queued prompt |
| Steer payload | Text-only in v1 |
| Maximum pending inputs | Bounded; reject when the queue limit is reached |
| Existing API compatibility | `send_message` still returns `:ok` on accepted input |

## 4. Target behavior

### 4.1 Send while idle

No semantic change:

1. The worker persists the user message to the durable transcript.
2. The session status becomes `streaming`.
3. The graph receives `ctx[:user_input]` and advances from `:receive`.

### 4.2 Send while running

When the worker state is `:generating`, `:executing_tools`, `:awaiting_approval`,
`:busy`, or `:query_loop`:

1. Validate the message using the existing content/image limits.
2. Create a pending input item with `kind: :queued_prompt`.
3. Store the item in a dedicated pending-input store, not in
   `Synapsis.Message`.
4. Broadcast a `queued_message` event so connected clients can render it.
5. Return `:ok`.

The active turn must not see queued prompts. This is the core safety rule: queued
prompts become transcript messages only when they are promoted at the next
`ReceiveMessage` wait point.

### 4.3 Queue promotion

Whenever graph-mode execution reaches `:receive` after a turn boundary:

1. Pop the oldest queued prompt.
2. Append it to `Synapsis.Message` as a regular user message.
3. Broadcast a queue status update so clients can mark the item as promoted.
4. Set `ctx[:user_input]` and `ctx[:image_parts]`.
5. Start the next turn automatically.

If multiple prompts are queued, only one prompt starts each turn. The next prompt
waits until that turn reaches `:receive`.

### 4.4 Steer while running

Steer is a new explicit action, separate from normal Send.

When accepted:

1. Validate text content with the same max byte limit as normal messages.
2. Store a pending input item with `kind: :steer`.
3. Add the steer text to worker context for the active turn.
4. Broadcast a `steer_message` event so connected clients can render it.
5. Return `:ok`.

Steer does not interrupt a provider stream, kill a tool process, deny a pending
permission request, or rewind graph state.

### 4.5 Steer consumption

`BuildPrompt` consumes pending steer items before constructing the provider
request. The steer text is added to the outgoing request as transient advisory
context for that request only. It is not appended to the durable transcript as a
normal user message.

After the prompt is built:

1. Mark consumed steer items as consumed in the pending-input store.
2. Broadcast a steer status update.
3. Clear those steer items from the worker context.

If a turn completes without another `BuildPrompt` after a steer is accepted, the
worker converts the unconsumed steer into the next queued prompt. That avoids
dropping user input.

## 5. Data model

Add a small pending-input model owned by the session layer.

Required fields:

| Field | Notes |
|-------|-------|
| `id` | UUID generated at acceptance time |
| `session_id` | Session owner |
| `kind` | `:queued_prompt` or `:steer` |
| `content` | Text content |
| `image_parts` | Only for queued normal prompts |
| `status` | `:pending`, `:promoted`, `:consumed`, `:cancelled`, or `:error` |
| `inserted_at` | UTC timestamp |
| `updated_at` | UTC timestamp |

Storage should use the existing Concord-backed session store through a dedicated
API. It must not use `Synapsis.Message` until a queued prompt is promoted.

## 6. Runtime architecture

### 6.1 Worker state

`Synapsis.Session.Worker` gains pending-input state:

- `queued_prompts`: ordered queue of pending prompt ids or loaded items.
- `pending_steers`: ordered list of active-turn steer ids or loaded items.

The worker remains the live read authority for in-flight state. Durable pending
inputs let queued prompts survive worker restart.

### 6.2 Worker API

Keep existing `send_message/3` for normal Send:

- idle graph mode: immediate turn, existing behavior.
- running graph mode: queue, return `:ok`.
- query-loop mode: queue while a query-loop task is running; if no task is
  running, existing send behavior.

Add a new `steer_message/2` or `steer_message/3` API:

- running graph mode: accept as steer.
- idle graph mode: treat as normal Send because there is no active step to
  steer.
- query-loop mode: queue as normal prompt in v1, because QueryLoop does not have
  the graph `BuildPrompt` injection point.

### 6.3 BuildPrompt integration

`Synapsis.Agent.Nodes.BuildPrompt` should read steer text from engine context and
append it to the provider request as transient guidance. The exact provider
message shape should be centralized in `MessageBuilder` or a small helper so the
steer formatting is consistent across providers.

The steer block should be visibly separated from user transcript content, for
example:

```text
Current-turn steering from the user:
<steer text>
```

This block is request-local and should not become a long-lived system prompt.

## 7. UI behavior

The LiveView input should stay enabled while the agent is running.

Controls:

- Default submit button: **Send**, always queues when running.
- Separate action: **Steer**, visible or enabled while running.
- Cancel remains available while running.

Rendering:

- Queued normal prompts appear in chat with a queued status until promoted.
- Promoted queued prompts become regular user messages after the worker appends
  them to the transcript.
- Steer items appear as current-turn steering notes, not normal chat turns.
- Consumed steer items show a consumed status.

The UI should not clear typed content until the server accepts the Send or Steer
action.

## 8. API and channel behavior

REST, channel, and LiveView must share the same semantics through
`Synapsis.Sessions`.

Required public surfaces:

- `POST /api/sessions/:id/messages`: normal Send. Accepted while running and
  queued when needed.
- `POST /api/sessions/:id/steer`: explicit Steer. A dedicated route avoids
  overloading normal message semantics.
- `session:message`: normal Send over channel.
- New `session:steer` channel event.

Busy errors should no longer be returned for accepted normal messages. Remaining
errors include invalid payload, content too large, too many images, queue full,
session not found, and worker unavailable.

## 9. Error handling

- Queue full: reject with `{:error, :queue_full}` and keep typed content in the UI.
- Worker restart: reload pending inputs from the pending-input store during boot.
- Cancel: cancel active work and leave queued prompts intact. Steer items for the
  cancelled turn become cancelled.
- Delete session: delete pending inputs with the session.
- Stale streaming recovery: pending queued prompts remain pending. Unconsumed
  steer items become queued prompts only if the worker can determine that the
  original active turn ended.

## 10. Tests

Use TDD for implementation. Focused tests should cover:

1. Worker queues `send_message` while graph mode is running.
2. Queued prompts are not appended to `Synapsis.Message` until promotion.
3. Queue promotion is FIFO at `:receive`.
4. Promoted queued prompt starts the next turn automatically.
5. Steer while running is accepted and does not cancel stream/tool state.
6. `BuildPrompt` injects steer text into the next provider request.
7. Consumed steer items are marked consumed and not reused.
8. Unconsumed steer becomes a queued prompt when the turn ends.
9. LiveView input remains enabled while streaming and can emit Send or Steer.
10. REST and channel callers see the same accepted/queued behavior.

Run scoped tests for touched apps:

- `mix test apps/synapsis_agent/test/synapsis/session/worker_test.exs`
- Relevant `apps/synapsis_core/test` pending-input tests.
- Relevant `apps/synapsis_server/test` route/channel tests.
- `mix test apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs`

## 11. Risks

1. **Transcript pollution.** Persisting queued prompts as normal messages too
   early would make the active turn read them. Pending inputs must stay outside
   `Synapsis.Message` until promotion.
2. **Ambiguous steer semantics.** Steer is advisory, not interrupting. UI text and
   API naming must make that clear.
3. **Unbounded queue growth.** The pending-input store must enforce a limit.
4. **QueryLoop parity.** QueryLoop lacks a `BuildPrompt` node, so steer support is
   graph-mode only in v1.
5. **Crash recovery.** Pending inputs must survive worker restart without
   replaying consumed steer items or duplicating promoted prompts.

## 12. Out of scope

- Interrupting or cancelling the current step through Steer.
- Editing, reordering, or deleting queued prompts.
- Branching a mid-turn prompt into a new session.
- Batching multiple queued prompts into one turn.
- Image steer payloads.
- Voice-style preemption.

## 13. Documents to update during implementation

- `docs/designs/synapsis-harness/adr-0006-mid-turn-input.md`: reopen the ADR and
  replace the v1 reject policy with queue-plus-advisory-steer.
- `docs/decisions/ADR-008-gen-statem-session-shell.md`: update the note that
  mid-turn prompt policy lives in the worker clause.
