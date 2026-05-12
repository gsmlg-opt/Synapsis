# ADR 0000 — Harness Architecture

- **Status:** Proposed
- **Date:** 2026-05-09
- **Deciders:** TBD
- **Related:** All subsequent ADRs

## Context

Synapsis is an AI coding agent built on the Elixir/OTP stack. The
v0 codebase (135 commits as of writing) established the umbrella
structure (`synapsis_core`, `synapsis_server`, `synapsis_cli`,
`synapsis_web`, `synapsis_lsp`) and several architectural primitives:
process-per-session, behaviour-based provider abstraction, PubSub
event bus, Port-sandboxed tool execution, GenServer-per-MCP-server.

What the v0 codebase does **not** yet have is a coherent answer to
the question: *where does the agent's decision-making logic live, and
how is it shaped?*

This is the question every AI agent codebase eventually answers, by
accident or by design. The accident-shaped answer is recognizable:
session GenServers grow to thousands of lines; tool dispatch is
tangled with streaming; permission logic is a flag-soup; testing
requires mocking the provider, the database, the tool runner, and
the PubSub bus all at once; adding a new provider means revisiting
every gen_statem callback. Most agent codebases — open source and
proprietary — have lived this trajectory.

The design-shaped answer takes one of a handful of forms. The
**harness architecture** — the form this ADR adopts — is the one
best matched to Elixir/OTP's strengths and to the FP principles the
team works under.

Three forces shape this decision:

1. **OTP biases the architecture toward processes.** Without a
   deliberate counterweight, "where does this logic go" answers
   itself as "in a GenServer callback," and the pure functional
   core dissolves into ambient state and message-passing concerns.
2. **Agent logic is mostly pure.** Given a conversation context and
   an event from the outside (provider chunk, tool result, user
   prompt), the question "what should happen next" is a pure
   function. The fraction that's effectful (write to socket, spawn
   tool, write to disk) is small and well-localized.
3. **The harness is the most-changed code in the codebase.** Every
   new provider, every new tool, every new permission rule, every
   new agent capability lives in or touches the harness. Its shape
   determines the change cost for the lifetime of the project.

## Decision

**Adopt a harness architecture: a pure functional core (`Loop.step/2`)
wrapped in an effectful OTP shell (`Session` gen_statem), with
swappable adapters at the edges (`Provider`, `Tool`, `Memory`,
`Store`).**

### The five-layer model

```
┌─────────────────────────────────────────────────────────────┐
│  Transport       │ synapsis_server (HTTP/SSE/Channels)      │
│                  │ synapsis_cli, synapsis_web               │
├──────────────────┼──────────────────────────────────────────┤
│  Shell           │ Session (gen_statem)                     │
│  (effects)       │ SessionSupervisor + SessionRegistry      │
│                  │ Telemetry, PubSub publication            │
├──────────────────┼──────────────────────────────────────────┤
│  Core            │ Loop.step/2  (pure reducer)              │
│  (pure)          │ Context.apply_event/2  (pure fold)       │
│                  │ Message, Part, Event ADTs (pure data)    │
├──────────────────┼──────────────────────────────────────────┤
│  Ports           │ Provider, Tool, Memory, Store            │
│  (behaviours)    │ (no implementation)                      │
├──────────────────┼──────────────────────────────────────────┤
│  Adapters        │ Provider.Anthropic, .OpenAI, .Mock       │
│  (effects)       │ Tool.Read, .Write, .Bash, ...            │
│                  │ Store.Postgres, Memory.SimpleCompactor   │
└──────────────────┴──────────────────────────────────────────┘
```

Dependencies only point inward. The Core knows nothing about the
Shell, Ports, or Adapters. Adapters know about Ports (they
implement them) but not about each other.

### Five claims this architecture makes

#### 1. The decision-making logic is pure

`Loop.step/2` is a function from `(Context, Input)` to `(Context,
NextAction, [Event], [Effect], [Broadcast])`. It reads no clocks,
opens no sockets, spawns no processes, raises no exceptions on valid
input. The full agent behavior — when to call tools, when to ask
permission, when to halt, when to compact context, when a turn ends
— is expressed as transitions in this function.

ADR 0005 locks the signature; Phase 2's task breakdown implements
it; CI's `mix synapsis.lint.purity` enforces it.

#### 2. The shell carries no logic

`Session` is a gen_statem whose only job is to translate I/O into
`Loop.Input` variants and `Loop.Effect` into I/O. Its callbacks read
as flat dispatch: receive an event, normalize, call `Loop.step/2`,
interpret the return tuple. If a `Session` callback contains a
`case` over agent state — what the user wants, what stage we're at,
what the model said — the callback is wrong. That logic belongs in
the Core.

The gen_statem's state set (`:idle | :generating |
:executing_tools | :awaiting_permission | :compacting | :halted`)
mirrors `Loop.NextAction` exactly. The state machine is the *shape*
of the agent's lifecycle; the reducer is its *content*.

#### 3. The event log is the source of truth

`Context` is the fold of all events:
`Enum.reduce(events, Context.new(...), &apply_event/2)`. This is
not a performance optimization; it is the *definition* of context.
Persistence is a projection (ADR 0001), crash recovery is replay
(no special path), tests use the same fold the runtime does (no
test-only mocking surface).

The events table is append-only. Deletes are themselves events
(ADR 0002). Versioning is forward-only (ADR 0003). The log
outlives every refactor.

#### 4. Providers, tools, memory, and storage are ports

Each is a behaviour: a small, stable set of callbacks the Core
calls. Adapters live at the edge; the Core never imports them.
This is what makes the codebase grow without grinding: a new
provider is an isolated change, a new tool is an isolated change,
swapping Postgres for ETS in tests is an isolated change.

Behaviours are deliberately narrower than the abstractions they
might tempt us toward. `Provider.stream/2` returns an `Enumerable`
of `ProviderEvent` variants, not a vendor-specific blob. `Tool.run/2`
returns a `ToolResult`, not a "whatever the tool wanted to return."
The normalization happens at the boundary, once.

#### 5. The architecture optimizes for change cost, not first-write cost

Writing the v1 harness with this shape costs more than writing a
single-file 2000-line `Session` GenServer that does everything.
That cost is paid up front. After v1, every change is local:
- Add a provider: one new module under `Provider.*`. No reducer
  changes.
- Add a tool: one new module under `Tool.*`. No reducer changes.
- Add a permission scope: one new variant in `Context.permissions`.
  No shell changes.
- Add a part type: one new variant in `Part`. No transport changes.

The break-even point arrives within Phase 7 (real tools). Beyond
that, every phase compounds the lead.

### What this is not

- **Not a framework.** No DSL, no macro magic, no
  `use Synapsis.Agent`. Plain modules, behaviours, ADTs.
- **Not a clean-architecture cargo cult.** The layer rules exist for
  the testability and change-locality benefits they produce. Any
  layer rule that fails to produce those benefits is a smell, not a
  principle.
- **Not a multi-agent orchestration framework.** Sub-sessions and
  the `task` tool are a Phase 8 feature, and they compose from the
  existing primitives. The harness is a *single* agent's runtime;
  multi-agent emerges from composition.
- **Not a tied-to-Anthropic design.** The `ProviderEvent` ADT
  abstracts vendor concepts at the boundary. The first adapter is
  Anthropic because that's the highest-fidelity stream; the second
  will be a local model via Ollama precisely to validate the
  abstraction.

## Consequences

### Positive

- **Testability.** The Core is testable with property tests and
  recorded fixtures, no processes, no I/O, no mocking framework.
  The shell is testable in integration with a mock provider and
  mock tools. The boundaries are clean enough that bugs localize
  quickly.
- **Change locality.** New providers, tools, part types, event
  variants — each is an additive change. The reducer is the only
  module that touches all of them, and it touches them through
  exhaustive pattern matching that the compiler audits.
- **Crash recovery for free.** Event sourcing + supervisor restart
  + pure fold = sessions survive BEAM crashes without special
  recovery code.
- **Telemetry and observability.** Every transition is a function
  call with explicit inputs and outputs; `:telemetry` spans wrap
  them naturally. The audit trail is the event log.
- **Replay and eval.** The same fold runs in production, in tests,
  and in offline eval harnesses. There is no separate "eval mode."
  Regression tests against recorded provider streams are mechanical.
- **OpenCode parity is achievable.** The data model maps cleanly to
  OpenCode's schema; the API surface is a thin layer over the
  reducer's existing semantics. Phase 6 is days of work, not weeks.

### Negative

- **Up-front cost.** Phases 1–2 are pure design and pure code with
  nothing visible to a user. Engineers (and managers) who measure
  progress in UI velocity will feel this. *Mitigation:* the phase
  plan ships a runnable demo at the end of every phase, even if the
  early demos are `iex`-only.
- **Conceptual overhead.** "Why don't we just put it in the
  GenServer?" is a question that will be asked many times. Each
  answer is in an ADR. *Mitigation:* link the ADR rather than
  re-argue; that's what ADRs are for.
- **The Core can absorb too much.** Pure code is fun to write; the
  Core can grow into a kingdom. *Mitigation:* the 30-LOC handler
  rule (Phase 2 cross-cutting expectations) keeps the reducer
  flat; the lint pass enforces purity but does not enforce
  cohesion — code review must.
- **Behaviours invite premature abstraction.** A `Memory`
  behaviour with one implementation is a smell, not a virtue.
  *Mitigation:* behaviours land *with* their first non-trivial
  implementation, not before; a single implementation is permitted
  to live as a module without a behaviour until a second one is
  imminent.
- **The pure/effect boundary is sometimes unobvious.** "Should this
  call into a tool, or emit an effect that triggers a tool?" The
  answer is always the latter, but the temptation is real.
  *Mitigation:* the lint pass catches sockets/processes; code
  review catches the more subtle cases.

### Neutral

- The architecture is biased toward the long-term shape of the
  product. If Synapsis pivots radically before Phase 7, the up-front
  cost looks like waste. The risk is real and is one a small team
  must weigh; this ADR assumes the bet is taken.

## Alternatives considered

### A. GenServer-centric ("the obvious OTP design")

One GenServer per session, callbacks contain agent logic, state is
the conversation, side effects happen inline.

Rejected because every agent codebase that started here has
regretted it. The GenServer grows linearly with feature count; the
boundaries between concerns dissolve; testing requires elaborate
mocks; new providers require revisiting every callback. The
incremental cost is invisible until you can't pay it.

### B. Actor-per-component

A `ProviderAgent`, a `ToolAgent`, a `MemoryAgent`, etc., all
communicating by message-passing. The "session" is the message
graph.

Rejected because it confuses *concurrency model* with *modular
decomposition*. The components don't need their own processes to
be modular; they need behaviours and a single coordinator. Multiple
processes add lifecycle complexity (who supervises what?), message
ordering uncertainty, and a debugging nightmare when an event
arrives at the wrong actor. The harness uses processes where
processes earn their keep (per-session, per-tool-execution,
per-MCP-server) and pure modules everywhere else.

### C. Event-sourced without the reducer

Persist events; rebuild state by reading them; let the gen_statem
callbacks do whatever they want between reads.

Rejected because half the benefit of event sourcing is the pure
fold. Without `apply_event/2`, replay is a fiction — the gen_statem's
callbacks have side effects in their decision-making, so replaying
the same events through different callback versions yields different
contexts. The reducer is what makes the log the source of truth in
practice, not just in theory.

### D. CQRS with separate command and query models

Commands flow through one path, queries through another, with
projections built asynchronously.

Rejected as disproportionate. CQRS earns its complexity when read
and write loads diverge by orders of magnitude. Single-user agent
sessions don't have that profile. The simpler model (one event log,
one projection, both written in the same transaction) handles the
load.

### E. Functional core / imperative shell — but no event sourcing

The reducer stays; durability is a `Store.save_context/2` call
rather than an event log.

Rejected because it loses crash recovery, replay, audit trail, and
the eval harness's foundation all at once. The benefit (slightly
less code) is dwarfed by the costs.

### F. Adopt an existing agent framework (LangChain, etc.)

Use a Python/TS framework via HTTP, or port one to Elixir.

Rejected because the existing frameworks are themselves examples of
the trajectory we're trying to avoid. Their internals look like
alternative A grown to maturity. Synapsis's reason to exist is
precisely that the agent harness can be done better in
Elixir/OTP/FP than in the Python ecosystem; importing the latter's
shape forfeits the reason.

## Validation

This ADR is correct iff, after Phases 1–7 ship:

- A new provider can be added in ≤ 1 person-day, with no changes to
  any module outside `Synapsis.Core.Provider.*`.
- A new tool can be added in ≤ 1 person-day, with no changes to any
  module outside `Synapsis.Core.Tool.*`.
- The reducer's property test suite stays green across all
  refactors.
- `Loop.step/2` remains under 500 LOC across all handlers combined.
- `Session` gen_statem stays under 300 LOC.
- Adding event sourcing to any new aggregate (e.g. Project, Workspace)
  reuses the same `apply_event/2` + `Store` machinery without
  bespoke code.

If any of these fail materially, the architecture has drifted and
this ADR is reopened to identify which principle stopped paying off.

## Process notes

- This is the keystone ADR. Subsequent ADRs (0001–0006 as of
  writing) either elaborate its claims or specify the protocols
  they imply.
- "Reopening this ADR" is a real option, not a rhetorical one.
  Architectural decisions have shelf lives; the shape of Synapsis in
  year three may warrant a different bet. The mechanism for that
  change is a successor ADR that explicitly supersedes this one.
- The architecture is opinionated about *shape* and unopinionated
  about *style*. Indentation, naming conventions, doc format are
  not this document's concerns. Style lives in code review.

## Appendix — How to read the ADR series

| ADR | Subject | Why it exists |
|---|---|---|
| 0000 | Harness architecture (this) | The top-level commitment |
| 0001 | Part storage | The hottest write path in the system |
| 0002 | Delete semantics | Event sourcing implications of "delete" |
| 0003 | Versioning | The event log is forever |
| 0004 | Streaming persistence | Write amplification at the edge |
| 0005 | Loop protocol | The keystone contract |
| 0006 | Mid-turn input | An intentional deferral |

A newcomer should read 0000, then 0005 (to understand the central
function), then the others as their phases come up. The remaining
ADRs assume 0000's claims as background.
