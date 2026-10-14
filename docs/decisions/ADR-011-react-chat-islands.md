# ADR-011: DuskMoon React Chat islands

## Status: Accepted

Partially supersedes [ADR-007](ADR-007-pure-liveview-ui.md). This is the user-authorized second phase following [ADR-010](ADR-010-react-form-islands.md).

## Decision

Agent sessions and Provider Test Chat use the published `dm_react_chat` and `createDuskmoonReactChat` integration. LiveView owns routes, session/runtime state, authorization, persistence, and request admission. React owns the ignored transcript subtree, Markdown, composer draft, attachment previews, and scroll behavior. No standalone SPA or channel package is introduced.

`SynapsisWeb.ChatBridge` maintains canonical presentation snapshots and per-message event sequences. Initial mount JSON stays frozen during streaming; deltas and message replacements travel through `chat:event`. Reconnects and sequence gaps request a canonical snapshot. Conversation-specific mount IDs prevent stale mounts from sending to another session; reselecting the same conversation retains sequence counters and admitted request IDs.

`SynapsisWeb.AgentLive.SessionChat` preserves ordered text, reasoning, image, file, tool and compaction parts alongside queued inputs, tool approvals, heartbeat notifications and code-agent status. Agent send, stop, retry, steer, regenerate and permission actions are checked against the current session and server state. Admitted send request IDs are deduplicated in a bounded cache.

`ask_user` questions remain owned by the live session Worker, including their correlation refs and waiting-task lifetime. The chat snapshot exposes pending questions so refresh and reconnect recover the answer form. React displays `Waiting for your answer`, optional choices and a free-text answer; the scoped `answer_question` action resolves the matching active question rather than queueing a prompt or steering the turn. Expired, cancelled or already answered refs are rejected, and question closure removes the form. Human question waits do not automatically retry on timeout.

The shared composer uses the public DuskMoon Chat components. A temporary submission helper preserves admission and acknowledgment behavior while providing UUIDv4 request IDs on ordinary HTTP origins: native `randomUUID`, then `getRandomValues`, then ordinary random bytes if Crypto is absent. These IDs are deduplication keys, not security tokens. This compatibility adapter is tracked by [upstream #198](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/198); dependency source and global browser APIs are not patched. The composer clears unchanged text and admitted attachments only after server acknowledgment, retains drafts on rejection or disconnect, and enforces the existing image limits. Agent sessions permit queueing while running and text-only steering; Provider Test Chat permits one active send and rejects attachments. Stop and Clear cancel the provider's owned stream task. Unmounting an Agent chat does not stop its persistent runtime.

## Consequences

The existing embedded storage and tool permission boundaries remain authoritative. Chat presentation depends on the published React integration and builds through DuskmoonBundler alongside application forms. Scoped bridge, Agent LiveView and Provider LiveView tests cover event ordering, recovery, scope, request admission, image/queue behavior and provider stream cancellation.

## Validation

The migration passed 95 scoped bridge/Agent/Provider tests, TypeScript checking, 17 hook/UUID tests, and scoped Elixir formatting. The DuskmoonBundler build emitted 14 JavaScript manifest entries with all referenced chunks present.

Browser checks used isolated configuration, Concord storage, fake session workers and a local SSE provider. They exercised rejected/admitted drafts, image removal and image-only sends, Queue, Steer, Stop, approvals, Retry, Regenerate, snapshot recovery after disconnect, conversation changes without stopping the Agent runtime, Provider Clear/Stop/errors and reopening during streaming. Desktop and 390px layouts in both themes had no horizontal overflow; browser consoles had no warnings or errors. These checks do not call external provider APIs.

An additional browser check on an ordinary HTTP LAN origin confirmed `isSecureContext=false` and `crypto.randomUUID` absent. The composer generated a valid UUIDv4 via the fallback, sent only one request on a double click, cleared admitted drafts and retained rejected drafts without console errors.
