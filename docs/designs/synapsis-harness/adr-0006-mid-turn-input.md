# ADR 0006 — Mid-Turn User Input

- **Status:** Proposed
- **Date:** 2026-05-09
- **Deciders:** TBD
- **Related:** ADR 0005 (Loop protocol), Phase 2 task B5, Phase 7
  (permissions & tools)

## Context

A user can send a prompt while the agent is still working on the
previous one. The model is mid-generation, a tool is mid-execution,
or the agent is awaiting permission. What should happen?

Every agent harness eventually answers this question. Most answer it
by accident — the first implementation that "worked" becomes the
contract, and three months later the support channel fills with
"why did my second message get dropped" and "why did Claude answer
the wrong question."

The OpenCode-parity v1 milestone does not require a sophisticated
answer. But it does require an *intentional* answer, because the
shape of the answer affects:

- The gen_statem state set (Phase 4)
- The `Loop.Input` ADT (ADR 0005)
- The API surface (Phase 6) — does `POST /session/{id}/prompt` 409
  when busy, or accept and queue?
- The permission system (Phase 7) — can a mid-turn prompt override
  a pending permission decision?

Three forces shape the decision:

1. **User mental model.** Chat-style interfaces train users to expect
   that sending a message *always works*. A 409 feels broken even
   when correct.
2. **Agent coherence.** A model whose context can mutate mid-turn is
   harder to reason about. Tool calls return to a different
   conversation than the one that started them.
3. **Implementation surface area.** Each strategy adds gen_statem
   states, edge cases, and tests. We are not on a deadline that
   justifies cutting corners on something this central.

## Decision

**v1 ships with "reject mid-turn input" as the default. The API
returns `409 Conflict` with a structured body explaining the agent
is busy and naming the alternatives (abort, then resend).**

The three serious alternatives (queue, interrupt, hybrid) are
documented below as roads not yet taken. Reopening this ADR is the
mechanism for taking one.

### v1 behaviour

When `UserPrompt` arrives and `Context.status != :idle`:

- The reducer returns `{:error, :session_busy}`.
- The shell maps this to `409 Conflict` with body:
  ```json
  {
    "error": "session_busy",
    "status": "generating | awaiting_tools | awaiting_permission",
    "current_message_id": "msg_...",
    "recovery": ["abort", "wait"]
  }
  ```
- The UI surfaces a one-click "abort current turn and send anyway"
  affordance that issues `POST /session/{id}/abort` followed by
  `POST /session/{id}/prompt`.

### Why "reject" beats the alternatives for v1

1. **It's the only option that requires zero new reducer logic.** The
   gen_statem state set stays minimal. Phase 2's exit criteria don't
   grow.
2. **It's the only option that can be upgraded later without
   breaking clients.** Going from reject → queue is purely additive
   (the 409 stops happening). Going from queue → reject is a
   breaking change.
3. **It surfaces the "what does the user want" question to the
   user.** The UI explicitly asks "abort and resend?" rather than
   the harness guessing.
4. **It avoids the permission interaction.** Mid-turn prompts during
   `:await_permission` are particularly delicate — does the new
   prompt implicitly cancel the pending permission request? Saying
   "rejected, abort first" sidesteps the entire question.

### What the gen_statem does

In every non-idle state, the `UserPrompt` event-handler clause:

```
handle_event({:call, from}, {:user_prompt, _parts}, state, data)
  when state in [:generating, :executing_tools, :awaiting_permission] ->
  {:keep_state_and_data, [{:reply, from, {:error, :session_busy}}]}
```

This is the only place in the codebase the v1 policy lives. Changing
the policy means changing this clause (and adding the corresponding
reducer logic).

## Consequences

### Positive

- **Simplest possible implementation.** Zero protocol changes, zero
  new reducer cases, zero new gen_statem states beyond Phase 2's
  base set.
- **Explicit user choice.** Abort-then-resend is a deliberate action;
  no surprise about which conversation the agent is in.
- **Upgrade path is clean.** Any of the alternatives below can
  replace this policy without breaking existing clients that handle
  409.
- **No ambiguity for downstream code.** Tool runners, permission
  prompts, projection writers all assume the session is single-turn.

### Negative

- **UX cost.** Users who type ahead lose what they typed unless the
  UI is careful to preserve the input across abort+resend.
  *Mitigation:* the UI keeps the textbox content until the new
  prompt is accepted; this is standard chat UX.
- **No "queue this for later" affordance.** Power users will want
  one. *Mitigation:* it is acknowledged as a future feature; not
  blocking v1.
- **Aborting loses work.** A long tool call that's 90% done gets
  cancelled. *Mitigation:* the user is making this choice
  explicitly; the UI surfaces "abort will lose current tool
  progress."
- **Mid-turn permission decisions are unaffected by the policy.**
  Wait — they shouldn't be: permission `granted`/`denied` are
  *separate* input variants, not `UserPrompt`. This is by design.
  The policy applies only to new prompts.

## Alternatives considered

These are documented thoroughly so the ADR amendment that adopts one
later doesn't have to redo the analysis.

### Alternative 1 — Queue

New prompts during a busy turn enter a per-session queue. When the
current turn reaches `:await_user`, the queued prompt becomes the
next turn.

**Pros:** Matches user expectation (sending always works). Preserves
all in-flight work. No 409 to handle.

**Cons:**
- Adds `Context.pending_prompts: [PromptRef.t()]`, an ordering rule
  for delivering them, and a property test that the queue empties
  on idle.
- Failure mode: a long-running turn can accumulate dozens of queued
  prompts; what does the user see? Each one becomes a separate
  conversation turn, retroactively in a different context than the
  user expected.
- Cancellation semantics are subtle. Can a user "unsend" a queued
  prompt? The UI must surface the queue.

**When to adopt:** when chat-style UX becomes the dominant interaction
mode and users complain that the agent feels "synchronous." A
worthwhile upgrade post-v1; not on the critical path.

### Alternative 2 — Interrupt / preempt

New prompts cancel the current turn (equivalent to abort + resend,
but in one operation). Optionally, the current turn's partial output
is preserved as a "stopped here" marker.

**Pros:** Maximally responsive. Matches voice-assistant interaction
patterns. No queue to surface.

**Cons:**
- Aggressive: the user might not realize they're cancelling a long
  tool call.
- Tool cancellation must be reliable and clean. Bash subprocess
  cleanup, file lock release, partial-write recovery — these become
  hot-path concerns.
- Asymmetric with permissions: should typing a new prompt
  implicitly deny a pending permission request? Either answer is
  surprising.

**When to adopt:** if voice / push-to-talk becomes a primary input
mode. Not without a dedicated UX pass.

### Alternative 3 — Hybrid

Reject during `:await_permission` (the user has an outstanding
decision; don't bypass it). Queue during `:generating` and
`:executing_tools`. Surface the queue in the UI.

**Pros:** Best of both worlds in principle.

**Cons:** Worst of both worlds in practice — every code path that
touches turn state has to know which sub-policy applies. Users
encounter both behaviors and have to learn the rules. Documentation
overhead.

**When to adopt:** after queue (alternative 1) has shipped and we've
measured which transitions actually need different behavior. Don't
introduce two policies before we've lived with one.

### Alternative 4 — Branch

A mid-turn prompt creates a new branch from the current message,
leaving the prior turn to complete on its own. The user navigates
between branches.

**Pros:** Mathematically clean. No state to mutate. Preserves history
perfectly.

**Cons:** UX is unfamiliar (branching conversations are not how chat
feels). Implementation requires the fork machinery from Phase 8 to
ship before chat is usable.

**When to adopt:** unlikely as a default; valuable as an option
("retry this from here") in advanced workflows. Don't conflate it
with mid-turn input handling.

## Validation

This decision is correct iff:

- The reducer rejects `UserPrompt` in every non-idle status with
  `{:error, :session_busy}` and emits zero events/effects.
- The API surface returns 409 with the documented body shape.
- Abort + resend produces a clean new turn with no leaked state from
  the cancelled one (property test).
- The UI handles 409 gracefully; the textbox content survives the
  cancel.

## Open questions

- Should the 409 body include an estimated time-to-idle? Probably
  not — over-specific and brittle. The UI's "still working…"
  indicator suffices.
- When abort-then-resend is invoked, do we want a single combined
  endpoint (`POST /session/{id}/restart-with-prompt`)? Ergonomic, but
  the same effect composes from two existing endpoints. Defer.
- Mid-stream input during `:await_tools` is different from
  `:generating` — tools may have side effects already in motion.
  Should the 409 body distinguish them more loudly? The `status`
  field already does. Sufficient.

## Process note

This ADR is unusual in that it locks in a *deferral*, not a
sophisticated decision. That's intentional. The cost of deferring
this question correctly (one 409 status code, one error variant) is
near zero. The cost of guessing wrong and having to migrate clients
later is large. Documenting why we're punting is itself the work.
