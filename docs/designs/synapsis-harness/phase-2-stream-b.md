# Phase 2 · Stream B — Reducer Handlers (Deep Dive)

> Companion to `phase-2-tasks.md`. Specifies the per-input transition
> behaviour of `Loop.step/2` at the granularity of "given this input
> in this context, here is what the reducer produces."
>
> Audience: whoever implements the Loop. Read this alongside ADR 0005
> (protocol) and the Phase 2 task list.

## How to read this document

For each input variant, the handler is specified as a pseudo-step
table:

| Precondition (on `Context`) | Events emitted | Effects emitted | Broadcasts emitted | `next` | Context mutation |

Tables are exhaustive over `Context.status`. The reducer's behaviour
for a `(status, input)` pair is the row at that intersection — or
the row marked `*` for "any status." Rows omitted are programmer
error (`{:error, _}`).

Notation:
- `[event_a, event_b]` — ordered list, emit in this order.
- `(none)` — empty list.
- `ctx.x ← y` — assignment to context field `x`.
- `{...}` — struct elided for brevity; assume fields named obviously.
- `<inferred>` — derived from the input or context, see notes.

The five-channel return shape from ADR 0005 is implicit; every
handler returns `{:ok, %{context, next, events, effects, broadcasts}}`
unless the cell is `{:error, reason}`.

---

## B5. `UserPrompt` handler

Input: `%UserPrompt{message_id, parts}`

| `Context.status`        | Events                                                                            | Effects                              | Broadcasts                       | `next`             | Mutation                                                                |
|-------------------------|-----------------------------------------------------------------------------------|--------------------------------------|----------------------------------|--------------------|-------------------------------------------------------------------------|
| `:idle`                 | `MessageAppended{role: :user, …}` then one `PartAppended{…}` per user part        | `[StartProviderStream{<inferred>}]`  | `[StatusChanged{:generating}]`   | `:await_provider`  | `status ← :generating`, `current_step ← nil` (set on `step_start`)      |
| `:generating`           | (none)                                                                            | (none)                               | (none)                           | unchanged          | **returns `{:error, :session_busy}`** — see ADR 0006                    |
| `:executing_tools`      | (none)                                                                            | (none)                               | (none)                           | unchanged          | `{:error, :session_busy}`                                               |
| `:awaiting_permission`  | (none)                                                                            | (none)                               | (none)                           | unchanged          | `{:error, :session_busy}`                                               |
| `:halted` / `:aborted`  | (none)                                                                            | (none)                               | (none)                           | unchanged          | `{:error, :inactive_session}` — distinct from busy; UI behaves differently |

Notes:
- `<inferred>` for `StartProviderStream` = `Loop.next_provider_input/1`
  (Phase 2 task B7) applied to the post-event context.
- `MessageAppended` precedes the `PartAppended` events because the
  fold requires the parent to exist before children attach. Ordering
  inside the events list matters; ADR 0005 codifies it.
- Validation of `parts` (non-empty, each variant well-formed) happens
  in the changeset at the API boundary (Phase 6); the reducer trusts
  its inputs structurally and crashes loudly on violations.

---

## B6.A `UserAbort` handler

Input: `%UserAbort{reason}` (default `reason = :user_requested`)

| `Context.status`        | Events                                                              | Effects                                                                                       | Broadcasts                  | `next`              | Mutation                                       |
|-------------------------|---------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|-----------------------------|---------------------|------------------------------------------------|
| `:idle`                 | (none)                                                              | (none)                                                                                        | (none)                      | unchanged           | `{:error, :nothing_to_abort}`                  |
| `:generating`           | `[Aborted{reason}]`                                                 | `[CancelProviderStream]`                                                                      | `[StatusChanged{:halted}]`  | `{:halt, reason}`   | cleared (see "cleanup invariant" below)        |
| `:executing_tools`      | `[Aborted{reason}]`                                                 | `[CancelTool{part_id} for each pending_tool]`                                                 | `[StatusChanged{:halted}]`  | `{:halt, reason}`   | cleared                                        |
| `:awaiting_permission`  | `[PermissionDenied{request_id, reason: :aborted}, Aborted{reason}]` | `[CancelTool{part_id} for each pending_tool]`                                                 | `[StatusChanged{:halted}]`  | `{:halt, reason}`   | cleared                                        |
| `:halted` / `:aborted`  | (none)                                                              | (none)                                                                                        | (none)                      | unchanged           | `{:error, :already_halted}`                    |

**Cleanup invariant** (referenced as "cleared"):
- `accumulating_parts ← %{}`
- `pending_tools ← %{}`
- `pending_permission ← nil`
- `current_step ← nil`
- `status ← :aborted`

Notes:
- During `:generating`, in-flight `accumulating_parts` are discarded
  with no `PartFinalized` event. Their `PartAppended{state: :streaming}`
  events remain in the log; the projection should treat orphan
  streaming parts as `state: :aborted` on read. Decide whether to
  emit explicit `PartAborted` events — recommendation: **yes**, one
  per stranded part, because the fold should be self-contained
  rather than requiring read-side rules.
- When aborting from `:awaiting_permission`, the `PermissionDenied`
  event must precede `Aborted` so a replay sees the permission
  resolved before the session terminates.

---

## B6.B `BudgetTick` handler

Input: `%BudgetTick{wall_clock_now}`

| `Context.status`        | Budget check fails?  | Behaviour                                                                                          |
|-------------------------|----------------------|----------------------------------------------------------------------------------------------------|
| any non-halted          | no                   | no-op return: `{:ok, %{context: ctx, next: <unchanged>, events: [], effects: [], broadcasts: []}}` |
| `:generating`           | yes                  | identical to `UserAbort{reason: :budget_exhausted}`                                                 |
| `:executing_tools`      | yes                  | identical to `UserAbort{reason: :budget_exhausted}`                                                 |
| `:awaiting_permission`  | yes                  | identical to `UserAbort{reason: :budget_exhausted}`                                                 |
| `:idle`                 | yes                  | should not happen (no work in flight); emit `{:error, :budget_check_in_idle}`                      |
| `:halted` / `:aborted`  | any                  | no-op                                                                                              |

Budget dimensions checked:
- `tokens_used >= tokens_max`
- `tool_calls_used >= tool_calls_max`
- `depth_used >= depth_max` (sub-session depth; relevant Phase 8+)
- `wall_clock_now - started_at >= wall_clock_max`

Each dimension records *which* limit tripped on the `Aborted` event's
`reason` field: `{:budget_exhausted, :tokens | :tool_calls | :depth |
:wall_clock}`. Useful for observability.

Notes:
- The reducer reads no clocks. `wall_clock_now` is supplied by the
  shell. Tests construct deterministic ticks.
- Token accounting is provider-reported (`step_finish.usage`), folded
  into `Context.budgets.tokens_used` during `step_finish` handling.
  `BudgetTick` reads, never writes.

---

## B3. `ProviderEvent` handler — the meat

Input: `%ProviderEvent{event: <variant>}`

The handler is a dispatch over the wrapped variant. Each sub-handler
is its own row group.

### B3.1 `:step_start`

Payload: `{step_id, model_id}`

| `Context.status` | Events                                              | Effects | Broadcasts                       | `next`             | Mutation                                                                            |
|------------------|-----------------------------------------------------|---------|----------------------------------|--------------------|-------------------------------------------------------------------------------------|
| `:await_provider`| `[StepStarted{step_id, model_id, message_id}]`      | (none)  | (none)                           | `:await_provider`  | `current_step ← %Step{id: step_id, model: model_id, started_at: <from input ts>}`, `status ← :generating` if not already |
| other            | (none)                                              | (none)  | (none)                           | unchanged          | `{:error, :step_start_outside_provider_state}`                                       |

Notes:
- `message_id` on `StepStarted` references the **assistant** message
  for this turn. The reducer creates this message on the first
  `:step_start` of a turn (lazy creation) via a `MessageAppended{role:
  :assistant}` event emitted *before* `StepStarted`. Subsequent
  `:step_start` events within the same turn reuse the existing
  assistant message id.
- Multiple steps per turn happen when a tool result triggers another
  model call. Same assistant message, new `Step` record.

### B3.2 `:text_delta`

Payload: `{part_id, fragment}`

| `Context.status` | Part exists in `accumulating_parts`? | Events                                              | Effects | Broadcasts                          | `next`            | Mutation                                                  |
|------------------|--------------------------------------|-----------------------------------------------------|---------|-------------------------------------|-------------------|-----------------------------------------------------------|
| `:generating`    | no                                   | `[PartAppended{part_id, type: :text, state: :streaming, body: ""}]` | (none)  | `[TextDelta{part_id, fragment}]`   | unchanged         | `accumulating_parts[part_id] ← %{type: :text, body: fragment}` |
| `:generating`    | yes                                  | (none)                                              | (none)  | `[TextDelta{part_id, fragment}]`   | unchanged         | `accumulating_parts[part_id].body <> fragment`              |
| other            | n/a                                  | (none)                                              | (none)  | (none)                              | unchanged         | `{:error, :delta_outside_generation}`                       |

Notes:
- Lazy `PartAppended`: emitted on the first delta for a part, not
  before. This matches what providers actually do (they don't
  announce a part until content arrives) and avoids speculative
  events for parts that never receive content.
- The streaming-state design comes straight from ADR 0004: events
  carry the structural fact ("a text part exists here"), broadcasts
  carry the fragments.

### B3.3 `:reasoning_delta`

Payload: `{part_id, fragment}`

Identical shape to `:text_delta` with `type: :reasoning` and
`ReasoningDelta` broadcast. No special handling.

### B3.4 `:tool_call_start`

Payload: `{part_id, tool_name}`

| `Context.status` | Tool registered?            | Events                                                                          | Effects | Broadcasts                                  | `next`     | Mutation                                                                              |
|------------------|-----------------------------|---------------------------------------------------------------------------------|---------|---------------------------------------------|------------|---------------------------------------------------------------------------------------|
| `:generating`    | yes                         | `[PartAppended{part_id, type: :tool, state: :pending, tool_name, args: %{}}]`   | (none)  | `[ToolArgsDelta{part_id, fragment: ""}]`    | unchanged  | `accumulating_parts[part_id] ← %{type: :tool, tool_name, args_buffer: "", state: :pending}` |
| `:generating`    | no                          | `[PartAppended{part_id, type: :tool, state: :error, tool_name, error: {:unknown_tool, tool_name}}]`  | (none)  | (none)                                      | unchanged  | (no accumulating entry; the tool will short-circuit to an error result at `complete`)  |
| other            | n/a                         | (none)                                                                          | (none)  | (none)                                      | unchanged  | `{:error, :tool_start_outside_generation}`                                            |

Notes:
- Unknown-tool handling is loud: the part is appended in `:error`
  state immediately, so the model's next turn (after `step_finish`)
  sees a structured "tool not found" result and can recover.
  Alternative — emit `{:error, :unknown_tool}` from the reducer —
  rejected because the provider has *already produced* this content;
  the agent must round-trip it back to the model rather than crash.

### B3.5 `:tool_call_args_delta`

Payload: `{part_id, fragment}`

| `Context.status` | Part in `accumulating_parts` as `:tool`? | Events  | Effects | Broadcasts                                | `next`     | Mutation                                                        |
|------------------|-------------------------------------------|---------|---------|-------------------------------------------|------------|------------------------------------------------------------------|
| `:generating`    | yes                                       | (none)  | (none)  | `[ToolArgsDelta{part_id, fragment}]`     | unchanged  | `accumulating_parts[part_id].args_buffer <> fragment`            |
| `:generating`    | no                                        | (none)  | (none)  | (none)                                    | unchanged  | `{:error, :tool_args_delta_without_start}`                       |

### B3.6 `:tool_call_complete`

Payload: `{part_id, args}` (`args` is the fully-parsed map; the
adapter is responsible for JSON parsing per ADR 0005)

| `Context.status` | Part state                  | Effect class needs permission? | Events                                                                              | Effects                                                | Broadcasts | `next` | Mutation                                                                      |
|------------------|-----------------------------|--------------------------------|-------------------------------------------------------------------------------------|--------------------------------------------------------|------------|--------|-------------------------------------------------------------------------------|
| `:generating`    | accumulating `:tool`        | no (read-only) OR pre-granted   | `[PartFinalized{part_id, state: :running, args, started_at: <ts>}]`                | `[StartTool{part_id, tool_name, args}]`               | (none)     | unchanged (still `:generating` until `step_finish`) | move part from `accumulating_parts` to `pending_tools[part_id] = %{state: :running}` |
| `:generating`    | accumulating `:tool`        | yes, not pre-granted            | `[PartFinalized{part_id, state: :awaiting_permission, args}, PermissionRequested{request_id, part_id, effect_class}]` | `[RequestPermission{request_id, part_id, tool_name, args, effect_class}]` | (none)     | unchanged (still `:generating`) | `pending_tools[part_id] = %{state: :awaiting_permission}`, `pending_permission = %{request_id, part_id}` |
| `:generating`    | accumulating in `:error`    | n/a                             | `[PartFinalized{part_id, state: :error, error: <stored>}]`                          | (none)                                                 | (none)     | unchanged | drop part from `accumulating_parts`; do **not** add to `pending_tools`         |
| other            | n/a                         | n/a                             | (none)                                                                              | (none)                                                 | (none)     | unchanged | `{:error, :tool_complete_outside_generation}`                                  |

Notes:
- `effect_class` (`:read | :write | :exec | :network`) is read from
  the tool's `effect/0` callback. The reducer doesn't import tool
  modules; the `Context` holds a snapshot of the registry at
  session-start, refreshed only on explicit re-load.
- `request_id` is a UUID v7 minted here. The `PermissionRequested`
  event carries the same id the `RequestPermission` effect surfaces
  to the UI; correlation is by this id.
- Parallel tool calls — multiple `:tool_call_complete` events within
  one step — accumulate: each adds to `pending_tools`. The state
  transition to `:await_tools` or `:await_permission` happens at
  `:step_finish`, not here. This is the right boundary because the
  provider hasn't told us it's done emitting tools until step ends.

### B3.7 `:step_finish`

Payload: `{step_id, stop_reason, usage}`

`stop_reason` ∈ `:end_turn | :tool_use | :max_tokens | :stop_sequence | :refusal`

| `stop_reason`   | Pending permission? | Pending tools? | Events                                                                                                     | Effects                                  | Broadcasts                       | `next`                  | Mutation                                                                              |
|-----------------|---------------------|----------------|------------------------------------------------------------------------------------------------------------|------------------------------------------|----------------------------------|-------------------------|---------------------------------------------------------------------------------------|
| `:end_turn`     | n/a (shouldn't be)  | n/a            | `[<finalize all accumulating text/reasoning parts via PartFinalized>, StepFinished{step_id, stop_reason, usage}]` | (none)                                   | `[StatusChanged{:idle}]`         | `:await_user`           | flush `accumulating_parts`, clear `current_step`, `tokens_used += usage`, `status ← :idle` |
| `:tool_use`     | yes                 | yes            | finalize text/reasoning + `StepFinished`                                                                   | (none — `RequestPermission` was emitted at `:tool_call_complete`)  | `[StatusChanged{:awaiting_permission}]`  | `:await_permission`     | flush text/reasoning from accumulating, `status ← :awaiting_permission`               |
| `:tool_use`     | no                  | yes            | finalize text/reasoning + `StepFinished`                                                                   | (none — `StartTool`s emitted earlier)    | `[StatusChanged{:executing_tools}]`  | `:await_tools`          | flush, `status ← :executing_tools`                                                    |
| `:tool_use`     | no                  | no             | (this is contradictory — provider said tool_use but no tools were emitted)                                  | (none)                                   | (none)                            | unchanged               | `{:error, :step_finish_tool_use_without_tools}`                                       |
| `:max_tokens`   | n/a                 | n/a            | finalize + `StepFinished` + `Aborted{reason: :max_tokens}`                                                 | (none)                                   | `[StatusChanged{:halted}]`       | `{:halt, :max_tokens}`  | cleanup invariant                                                                     |
| `:stop_sequence`| n/a                 | n/a            | identical to `:end_turn`                                                                                   |                                          |                                  |                         |                                                                                       |
| `:refusal`      | n/a                 | n/a            | finalize + `StepFinished` + `Aborted{reason: :refusal}`                                                    | (none)                                   | `[StatusChanged{:halted}]`       | `{:halt, :refusal}`     | cleanup invariant                                                                     |

Notes:
- Finalization of text/reasoning parts emits `PartFinalized` events
  carrying the full assembled body. The broadcast channel already
  delivered the deltas; finalization is what makes the part durable.
- The `:end_turn` + pending-tools combination is impossible from a
  well-behaved provider but defensively: if it happens, treat the
  pending tools as cancelled (emit `ToolFailed` events with reason
  `:provider_inconsistency`) and proceed to `:idle`. Add a row.
- Token accounting from `usage` is folded into budgets here, *before*
  the budget check that would otherwise miss it.

### B3.8 `:done`

The adapter signals end-of-stream. Should always follow
`:step_finish`. If it arrives in `:await_provider` without an
intervening `:step_finish`, that's a protocol violation:

| `Context.status`  | Followed `:step_finish`? | Behaviour                                                                                              |
|-------------------|---------------------------|--------------------------------------------------------------------------------------------------------|
| any non-provider  | n/a                       | no-op (defensive)                                                                                       |
| `:await_provider` | yes                       | no-op (the `:step_finish` already advanced state)                                                       |
| `:await_provider` | no                        | treat as `ProviderError{reason: :unexpected_done}` — produces `Aborted{reason}` + cleanup               |

### B3.9 `:error` (provider stream error)

Payload: `{reason, retriable?}`

| `retriable?` | Events                                              | Effects                                | Broadcasts                       | `next`                  | Mutation                  |
|--------------|-----------------------------------------------------|----------------------------------------|----------------------------------|-------------------------|---------------------------|
| false        | `[Aborted{reason: {:provider_error, reason}}]`      | `[CancelProviderStream]`               | `[StatusChanged{:halted}]`       | `{:halt, ...}`          | cleanup invariant         |
| true         | `[ProviderRetryRequested{reason}]`                  | `[StartProviderStream{<new request>}]` | `[StatusChanged{:retrying}]`     | `:await_provider`       | retry counter increments  |

Notes:
- Retry behaviour is a v1+ feature; for v1, treat all provider errors
  as non-retriable in the reducer. The `retriable?` flag is preserved
  in the ADT so adapters can start marking errors *now*, and the
  retry handler is a single-row addition later.
- Retry counter lives in `Context.budgets.provider_retries`; exceeds
  threshold → fall through to non-retriable branch.

---

## B4. Tool-result and permission handlers

### B4.1 `ToolStarted`

Input: `%ToolStarted{part_id}`

| `Context.status`     | `part_id` in `pending_tools` with state `:running`? | Events                                  | Effects | Broadcasts                                | `next`     | Mutation                                                  |
|----------------------|-----------------------------------------------------|-----------------------------------------|---------|-------------------------------------------|------------|------------------------------------------------------------|
| `:await_tools`       | yes (means optimistic start already done)            | (none)                                  | (none)  | (none)                                    | unchanged  | no-op                                                      |
| `:await_tools`       | yes, state `:awaiting_permission`                    | (none)                                  | (none)  | (none)                                    | unchanged  | `{:error, :tool_started_before_permission}`                |
| `:await_tools`       | yes, state `:starting`                               | `[PartUpdated{part_id, state: :running, started_at: <ts>}]` | (none)  | (none)                                    | unchanged  | `pending_tools[part_id].state ← :running`                  |
| other                | n/a                                                  | (none)                                  | (none)  | (none)                                    | unchanged  | `{:error, :tool_started_outside_executing}`                |

Notes:
- The "optimistic start" pattern: when the reducer emits `StartTool`,
  it sets the part state to `:running` immediately (predicted, not
  confirmed). The shell's `ToolStarted` input is a *confirmation*; if
  it doesn't arrive, the eventual `ToolFailed` will correct the
  state. This avoids a `:starting → :running` transition for the
  common case but admits the alternative if Phase 7 finds the
  optimism causes UX bugs.

### B4.2 `ToolCompleted`

Input: `%ToolCompleted{part_id, result}`

| `Context.status`     | All pending tools complete after this? | Events                                                                                          | Effects                                                            | Broadcasts                       | `next`                | Mutation                                                              |
|----------------------|-----------------------------------------|-------------------------------------------------------------------------------------------------|--------------------------------------------------------------------|----------------------------------|-----------------------|------------------------------------------------------------------------|
| `:await_tools`       | no                                      | `[ToolReturned{part_id, result}, PartUpdated{part_id, state: :completed, result}]`              | (none)                                                             | (none)                           | `:await_tools`        | `pending_tools` drops `part_id`                                        |
| `:await_tools`       | yes                                     | `[ToolReturned{part_id, result}, PartUpdated{part_id, state: :completed, result}]`              | `[StartProviderStream{<inferred from updated context>}]`           | `[StatusChanged{:generating}]`   | `:await_provider`     | `pending_tools` empties; `status ← :generating`                        |
| other                | n/a                                     | (none)                                                                                          | (none)                                                             | (none)                            | unchanged             | `{:error, :tool_completed_outside_executing}`                          |

### B4.3 `ToolFailed`

Input: `%ToolFailed{part_id, error}`

Identical structure to `ToolCompleted`; events become
`[ToolFailed{part_id, error}, PartUpdated{part_id, state: :error,
error}]`. The model receives this as a structured failure result on
its next step.

Notes (for both):
- Order of events matters: `ToolReturned`/`ToolFailed` precedes
  `PartUpdated`. The fold reads it as "the result fact happened, then
  the part's state reflects it." Useful for projection writers that
  treat results as audit-log entries.
- Cancellation due to abort produces `ToolFailed{error: {:cancelled,
  reason}}` via the same handler — the shell synthesizes the input.

### B4.4 `PermissionGranted`

Input: `%PermissionGranted{request_id, scope}`

`scope` is the set of capabilities the user approved (may be broader
than the specific request — e.g. "grant fs_write for this session").

| `Context.status`            | `request_id` matches `pending_permission`? | Events                                                                                                   | Effects                                                                                              | Broadcasts                       | `next`                                                            | Mutation                                                                       |
|-----------------------------|---------------------------------------------|----------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|----------------------------------|-------------------------------------------------------------------|---------------------------------------------------------------------------------|
| `:awaiting_permission`      | yes                                         | `[PermissionGranted{request_id, scope}]` + for each newly-eligible tool: `[PartUpdated{part_id, state: :running}]` | `[StartTool{...} for each newly-eligible tool]`                                                      | `[StatusChanged{:executing_tools}]` | `:await_tools` if any tools dispatched, else `:await_provider` (re-stream) | `permissions ← permissions ∪ scope`; move eligible pending_tools from `:awaiting_permission` to `:running`; clear `pending_permission` if no more pending |
| `:awaiting_permission`      | no                                          | (none)                                                                                                   | (none)                                                                                               | (none)                            | unchanged                                                         | `{:error, :stale_permission_request}` — the request is no longer current        |
| other                       | n/a                                         | (none)                                                                                                   | (none)                                                                                               | (none)                            | unchanged                                                         | `{:error, :permission_grant_in_wrong_state}`                                    |

Notes:
- A grant may cover *multiple* pending tools (the user granted a
  broad scope; several pending tool calls match). All eligible tools
  dispatch in this one transition.
- If no tools are eligible after the grant (e.g. user granted a
  scope unrelated to what's actually pending), the session remains
  in `:awaiting_permission` for the next request. Edge case but
  reachable.
- The "re-stream if no tools dispatched" branch handles a subtle
  case: permission was for a *previously-completed* tool that
  retroactively needs re-running. v1 should not support this; emit
  `{:error, :no_tools_to_dispatch}` instead. Keep the structure
  documented for Phase 7+.

### B4.5 `PermissionDenied`

Input: `%PermissionDenied{request_id}`

| `Context.status`        | Matches pending? | Events                                                                                                          | Effects                                                  | Broadcasts                       | `next`                | Mutation                                                              |
|-------------------------|------------------|-----------------------------------------------------------------------------------------------------------------|----------------------------------------------------------|----------------------------------|-----------------------|------------------------------------------------------------------------|
| `:awaiting_permission`  | yes              | `[PermissionDenied{request_id}, ToolFailed{part_id, error: :denied}, PartUpdated{part_id, state: :error}]` for each blocked tool, then `StepFinished` only if no tools remain | `[StartProviderStream{<inferred>}]`                      | `[StatusChanged{:generating}]`   | `:await_provider`     | clear `pending_permission`; drop denied tools from `pending_tools`     |
| other                   | n/a              | (none)                                                                                                          | (none)                                                   | (none)                            | unchanged             | `{:error, :denial_in_wrong_state}`                                     |

Notes:
- Denial does **not** halt the agent. The denied tool returns a
  structured error to the model, which may pivot or surface the
  failure to the user. This is what "permissions as data, not control
  flow" means in practice.
- If multiple tools share the denied request (one prompt covered
  several pending tools), all fail together.

---

## Cross-handler invariants

The following hold across every handler. They are property tests
(Phase 2 E3) but stating them here keeps each handler's contract
honest.

### Invariant 1 — Cleanup at halt

After any handler returns `next = {:halt, _}`:
- `accumulating_parts == %{}`
- `pending_tools == %{}`
- `pending_permission == nil`
- `current_step == nil`
- `status ∈ [:aborted, :halted]`

The cleanup is emitted as part of the same transition (via the
`Aborted` event's fold), not deferred.

### Invariant 2 — Cleanup at idle

After any handler returns `next = :await_user`:
- `accumulating_parts == %{}`
- `pending_tools == %{}`
- `pending_permission == nil`
- `current_step == nil`
- `status == :idle`

This is what makes "session is ready for next prompt" a structural
fact rather than an optimistic guess.

### Invariant 3 — Event/fold consistency

For every handler return value:
`Enum.reduce(events, old_context, &apply_event/2) == new_context`.

The reducer is allowed to compute `new_context` directly (no need to
re-fold for performance), but the property must hold. Property test
verifies on random inputs.

### Invariant 4 — Effect/event correspondence

For every `StartTool` effect, there is a preceding `PartFinalized`
or `PartUpdated` event that puts the part in `:running` state. For
every `StartProviderStream`, there is a context transition that
warrants a model call (new user message, completed tools, granted
permission unblocking tools). Effects never appear "ambiently" —
they always correspond to an event.

This is loose ("warrants" is judgment) but the audit is:
post-replay, every `StartProviderStream` ever issued must have a
plausible predecessor event in the log. Useful for debugging
"why did we call the provider here."

### Invariant 5 — Broadcasts never imply state

A subscriber that receives only broadcasts and never reads the
projection is allowed to be ignorant of *what state the session is
in*. Concretely: never emit a broadcast that the projection
wouldn't eventually corroborate. The reducer's broadcasts are a
strict subset of the information in its events plus the
accumulating-parts state, and the latter is always durable up to
the last `PartFinalized`.

This invariant is what makes the broadcast channel safe to drop on
the floor (ADR 0004's central claim).

---

## Handler implementation guidance

### One handler per file

`Synapsis.Core.Loop.Handlers.UserPrompt`,
`Synapsis.Core.Loop.Handlers.ProviderEvent.StepStart`, etc.
`Loop.step/2` is dispatch only; each handler is a focused module
with one public function.

This keeps the 30-LOC handler rule meaningful: handlers can't
trivially share helpers via accident, so any shared helper has to be
named and put somewhere (likely `Synapsis.Core.Loop.Helpers`).

### The builder pattern

```elixir
defmodule Synapsis.Core.Loop.Builder do
  defstruct context: nil, events: [], effects: [], broadcasts: [], next: nil

  def new(context), do: %__MODULE__{context: context}
  def event(b, e), do: %{b | events: b.events ++ [e]}
  def effect(b, e), do: %{b | effects: b.effects ++ [e]}
  def broadcast(b, br), do: %{b | broadcasts: b.broadcasts ++ [br]}
  def next(b, n), do: %{b | next: n}
  def commit(b, new_ctx), do: %{b | context: new_ctx}
  def build(b), do: {:ok, %{
    context: b.context, next: b.next,
    events: b.events, effects: b.effects, broadcasts: b.broadcasts
  }}
end
```

Every handler reads as:

```elixir
Builder.new(context)
|> Builder.event(%PartAppended{...})
|> Builder.broadcast(%TextDelta{...})
|> Builder.commit(updated_context)
|> Builder.next(:await_provider)
|> Builder.build()
```

Flat, append-only, no intermediate state to track.

### Context updates: apply_event/2 in the builder

The builder's `commit/2` accepts a hand-computed context, but the
preferred pattern is `commit_via_events/1` that folds the
accumulated events onto the starting context. This makes Invariant 3
structurally true rather than test-verified:

```elixir
def commit_via_events(b) do
  ctx = Enum.reduce(b.events, b.context, &Context.apply_event/2)
  %{b | context: ctx}
end
```

Use this in handlers where it doesn't hurt clarity. Use direct
`commit/2` only when the new context needs fields that aren't event-
derived (`accumulating_parts` mutations, primarily — these are
in-memory only and don't fold from events).

### Avoid clever dispatch

Pattern-match `ProviderEvent` sub-variants explicitly in
`Loop.step/2`'s dispatch table; don't use a `Map` or `Module.concat`
trick. The compiler's exhaustiveness check on the `case` is one of
the strongest tools the codebase has. Don't give it up to save a
few lines.

---

## Sequencing for implementation

The handlers in dependency order, for a single engineer:

1. **`UserPrompt :idle` only.** Smallest cycle: create session → send
   prompt → get `StartProviderStream` effect. Verify the event log.
2. **`ProviderEvent :step_start` + `:text_delta` + `:step_finish:end_turn`.**
   Smallest end-to-end: model says hi, no tools. Verify the
   accumulating → finalized transition.
3. **`UserAbort` from `:generating`.** Verify cleanup invariant 1
   triggers properly.
4. **`ProviderEvent` tool flow without permission.** All of B3.4–B3.7
   for read-only tools.
5. **`ToolCompleted` + `ToolFailed` (B4.2, B4.3).** Round-trip through
   `:await_tools` back to `:await_provider`.
6. **Permission flow.** B3.6 with permission, B4.4, B4.5.
7. **`BudgetTick`.** Once everything else works, prove the reducer
   shuts itself down on budget exhaustion.
8. **Edge cases.** Provider errors, unknown tools, stale permissions,
   contradictory `step_finish` payloads.

Each step is a commit with its scenario test from Phase 2 E2 going
green. The sequence guarantees that at each step, the previous step's
scenarios stay green.

---

## What this document deliberately doesn't cover

- **`Loop.next_provider_input/1`.** Phase 2 task B7. The pure function
  that translates `Context` into a provider request. Specified
  separately because it's a *projection*, not a *transition*.
- **Compaction.** Phase 9. `Memory.compact/1` is invoked from the
  reducer when token budget approaches the cap, but the trigger and
  policy live in their own design.
- **Sub-sessions and the `task` tool.** Phase 8. Treated as a
  tool-with-special-effect; doesn't change handler shape.
- **Multi-turn user input queueing.** Deferred (ADR 0006). The
  current `UserPrompt :generating` row stays as `{:error,
  :session_busy}` until the deferral is revisited.

When those phases arrive, this document gets a sequel rather than a
revision.
