# Session subagents implementation record

Scope: default-enabled session subagents using published Backplane 1.10.26,
preserving the session shell, current host tools and explicit opt-outs.
Architecture and current limits are recorded in
[Session subagents](../../architecture/08_SUBAGENTS.md).

- [x] Upgrade only `backplane_agent_runtime` and its lock entry.
- [x] Add a data-only Concord journal, runtime Store adapter and conformance tests.
- [x] Bind real root/child Conversations through `Codex.Session` and `MultiAgent`.
- [x] Preserve exact policy/approval identity and immutable child inheritance.
- [x] Append canonical terminal history atomically in a supervised task.
- [x] Fence adapter generations; preserve unknown outcomes without replay.
- [x] Add the session toggle, roster, child approvals and recovery display.
- [x] Exercise native chains, nested/followup work, capacity, policy, recovery,
  Bypass HTTP execution, queues and cancel-to-next-turn behavior in focused tests.
- [x] Preserve completed tool history during cancellation and settle fatal prompt
  failures; retain recovery fencing if canonical history is unavailable.
- [x] Pass 356 scoped tests, build assets, and verify the toggle and persisted
  setting in an isolated browser session with no console errors.
- [x] Verify default-enabled execution and explicit opt-out persistence.

Delivery uses `cmd-worktree-merge`: commit the feature, merge into `main` and
clean up the feature worktree and branch.
