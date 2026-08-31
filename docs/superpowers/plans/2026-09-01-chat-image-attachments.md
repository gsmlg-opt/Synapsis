# Chat Image Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver images selected in the existing DuskMoon chat input to providers as validated Base64 JSON image parts and show them consistently in session history.

**Architecture:** A Synapsis-owned hook specializes the existing `WebComponentHook` only for `el-dm-chat-input`: it converts `File[]` to Base64 JSON, sends `images` with the text, and waits for a LiveView `clear_chat_input` event before clearing. `Synapsis.Image` validates and converts the JSON maps into `Synapsis.Part.Image` structs; the existing worker persistence and provider mappers carry those structs through the turn. LiveView rendering and REST serialization gain explicit `Part.Image` clauses.

**Tech Stack:** TypeScript, Node test runner, Phoenix LiveView, Elixir 1.18, ExUnit, DuskMoon custom elements, Concord session storage.

---

## File Map

- Create `packages/hooks/src/chat-image-input.ts`: Base64 conversion plus the dedicated chat-input LiveView hook.
- Create `packages/hooks/test/chat-image-input.test.ts`: real hook lifecycle and payload tests with in-memory files.
- Modify `packages/hooks/src/index.ts`: export and register `ChatImageInputHook`.
- Modify `apps/synapsis_web/assets/js/app.ts`: route only `el-dm-chat-input` through the specialized hook and preserve the upstream hook for every other element.
- Modify `apps/synapsis_core/lib/synapsis/image.ex`: validate Base64 JSON payloads and return `Part.Image` structs.
- Modify `apps/synapsis_core/test/synapsis/image_test.exs`: cover payload decoding, signatures, limits, and atomic rejection.
- Modify `apps/synapsis_core/lib/synapsis/sessions.ex`: add a direct `send_message/3` image-part path.
- Modify `apps/synapsis_agent/lib/synapsis/session/worker/persistence.ex`: omit an empty text part for image-only prompts.
- Modify `apps/synapsis_agent/test/synapsis/session/worker_test.exs`: prove image-only persistence.
- Modify `apps/synapsis_web/lib/synapsis_web/live/agent_live/sessions.ex`: decode images, preserve attachments on failure, include image parts in optimistic messages, and clear on acceptance.
- Modify `apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs`: cover hook markup, valid/invalid/image-only/queued flows, clear event, and rendering.
- Modify `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`: render image parts with DuskMoon-compatible token classes.
- Modify `apps/synapsis_server/lib/synapsis_server/controllers/session_controller.ex`: serialize image parts.
- Modify `apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs`: replace the current `unknown` expectation with the image JSON contract.

### Task 1: Encode browser files as Base64 JSON without premature clearing

**Files:**
- Create: `packages/hooks/src/chat-image-input.ts`
- Create: `packages/hooks/test/chat-image-input.test.ts`
- Modify: `packages/hooks/src/index.ts`
- Modify: `apps/synapsis_web/assets/js/app.ts`

- [ ] **Step 1: Write failing TypeScript tests**

Add tests that mount the wished-for hook on a fake `EL-DM-CHAT-INPUT`, emit `send` with an in-memory PNG file, and assert the pushed payload is exactly:

```ts
{
  value: "describe",
  images: [{name: "pixel.png", media_type: "image/png", data: "iVBORw=="}],
}
```

Also assert `setValue` and `clearFiles` are not called immediately; invoke the registered `clear_chat_input` handler and then assert both are called. Add separate tests for an image-only prompt, `arrayBuffer()` rejection pushing `image_attachment_error`, and lifecycle cleanup removing listeners and disconnecting the field-semantics observer.

- [ ] **Step 2: Run the hook tests and verify RED**

Run:

```bash
npm run test:hooks -- --test-name-pattern="chat image"
```

Expected: FAIL because `chat-image-input.ts` and `ChatImageInputHook` do not exist.

- [ ] **Step 3: Implement the minimal hook**

Define JSON-safe types and a chunked browser-safe encoder:

```ts
export type ChatImagePayload = {
  name: string
  media_type: string
  data: string
}

export async function encodeChatImages(files: readonly File[]): Promise<ChatImagePayload[]> {
  return Promise.all(files.map(async (file) => ({
    name: file.name,
    media_type: file.type,
    data: bytesToBase64(new Uint8Array(await file.arrayBuffer())),
  })))
}
```

`ChatImageInputHook.mounted` must observe field semantics, listen for `send`, guard against a second send while encoding, push `send_message`, register `clear_chat_input`, and push only a short safe message on `image_attachment_error`. `destroyed` removes the listener and disconnects the observer. Export it from `packages/hooks/src/index.ts`.

In `app.ts`, delegate `mounted`/`updated`/`destroyed` to `ChatImageInputHook` when `this.el.tagName === "EL-DM-CHAT-INPUT"`; keep the upstream DuskMoon hook unchanged for all other custom elements.

- [ ] **Step 4: Run hook tests and typecheck to verify GREEN**

Run:

```bash
npm run test:hooks
npm run typecheck
```

Expected: all hook tests pass and TypeScript exits 0.

- [ ] **Step 5: Commit the client seam**

```bash
git add packages/hooks/src/chat-image-input.ts packages/hooks/test/chat-image-input.test.ts packages/hooks/src/index.ts apps/synapsis_web/assets/js/app.ts
git commit -m "fix(web): encode chat images for LiveView"
```

### Task 2: Validate Base64 JSON images at the core boundary

**Files:**
- Modify: `apps/synapsis_core/lib/synapsis/image.ex`
- Modify: `apps/synapsis_core/test/synapsis/image_test.exs`

- [ ] **Step 1: Write failing decoder tests**

Add `decode_payloads/1` tests for:

```elixir
assert {:ok, [%Synapsis.Part.Image{media_type: "image/png", data: encoded}]} =
         Image.decode_payloads([
           %{"name" => "pixel.png", "media_type" => "image/png", "data" => encoded}
         ])
```

Cover valid PNG, JPEG, GIF, and WebP signatures. Assert errors for malformed Base64, empty data, unsupported media type, signature mismatch, more than four images, a decoded image above 5 MiB, aggregate decoded bytes above 10 MiB, and a non-list payload. For a list containing one valid and one invalid item, assert one error and no partial result.

- [ ] **Step 2: Run the image tests and verify RED**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_core/test/synapsis/image_test.exs
```

Expected: FAIL with `undefined function Synapsis.Image.decode_payloads/1`.

- [ ] **Step 3: Implement pure validation functions**

Add constants for four images, 5 MiB per image, 10 MiB aggregate, and the four supported MIME types. Implement `decode_payloads/1` with pattern matching and `with`; decode strictly with `Base.decode64/1`, compare the declared MIME type against magic bytes, accumulate decoded byte counts, and return canonical `Synapsis.Part.Image` structs containing the original Base64. Do not log or persist decoded bytes.

- [ ] **Step 4: Run image tests and verify GREEN**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_core/test/synapsis/image_test.exs
```

Expected: all image tests pass.

- [ ] **Step 5: Commit validation**

```bash
git add apps/synapsis_core/lib/synapsis/image.ex apps/synapsis_core/test/synapsis/image_test.exs
git commit -m "feat(core): validate JSON image payloads"
```

### Task 3: Preserve canonical image parts through session entry and persistence

**Files:**
- Modify: `apps/synapsis_core/lib/synapsis/sessions.ex`
- Modify: `apps/synapsis_agent/lib/synapsis/session/worker/persistence.ex`
- Modify: `apps/synapsis_agent/test/synapsis/session/worker_test.exs`

- [ ] **Step 1: Write a failing image-only persistence test**

Call `Persistence.persist_user_message/3` with blank text and one `Part.Image`, then assert the durable user message has exactly one image part and no empty `Part.Text`:

```elixir
assert :ok = Persistence.persist_user_message(session.id, "", [image])
assert [%Message{parts: [%Part.Image{}]}] = Message.list_by_session(session.id)
```

Add a companion assertion that nonblank text remains first, followed by the images.

- [ ] **Step 2: Run the worker test and verify RED**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_agent/test/synapsis/session/worker_test.exs
```

Expected: FAIL because persistence currently always prepends an empty text part.

- [ ] **Step 3: Implement minimal canonical-part construction**

Build user parts as `image_parts` when `String.trim(content) == ""`; otherwise use `[%Part.Text{content: content} | image_parts]`. Add `Synapsis.Sessions.send_message/3` with guards for binary content and a list of `Part.Image` structs, delegating to the existing worker call without writing files.

- [ ] **Step 4: Run worker and session-related tests to verify GREEN**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_agent/test/synapsis/session/worker_test.exs apps/synapsis_data/test/synapsis/session/pending_input_store_test.exs
```

Expected: both suites pass.

- [ ] **Step 5: Commit the session path**

```bash
git add apps/synapsis_core/lib/synapsis/sessions.ex apps/synapsis_agent/lib/synapsis/session/worker/persistence.ex apps/synapsis_agent/test/synapsis/session/worker_test.exs
git commit -m "feat(session): preserve image-only prompts"
```

### Task 4: Accept image JSON in the Agent LiveView

**Files:**
- Modify: `apps/synapsis_web/lib/synapsis_web/live/agent_live/sessions.ex`
- Modify: `apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs`

- [ ] **Step 1: Write failing LiveView tests**

Update the input markup assertion to require the specialized behavior and no `clear-on-send` attribute. Add tests that render the `send_message` hook with a valid Base64 PNG and assert the durable user message contains `Text` plus `Image`; send blank text with one image and assert image-only persistence; set the worker running and assert the queued input keeps `image_parts`; assert invalid Base64 displays a safe error, persists/queues nothing, and emits no `clear_chat_input`. For accepted text and image messages, assert:

```elixir
assert_push_event(view, "clear_chat_input", %{})
```

- [ ] **Step 2: Run the LiveView tests and verify RED**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs
```

Expected: FAIL because the handler ignores `images`, empty text is rejected, and the input clears locally.

- [ ] **Step 3: Implement the LiveView boundary**

Add the `%{"value" => content, "images" => images}` event clause before the text-only compatibility clauses. Decode with `Synapsis.Image.decode_payloads/1`, then call a private `send_message(content, image_parts, socket)`. Permit a blank string only when images are present, build optimistic parts with the same blank-text rule as persistence, call `Sessions.send_message/3`, and `push_event(socket, "clear_chat_input", %{})` only on `:ok`. Add an `image_attachment_error` event that shows a fixed safe flash message. Remove `clear_on_send` from `<.dm_chat_input>` while keeping the existing DuskMoon component and field semantics.

- [ ] **Step 4: Run LiveView tests and verify GREEN**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs
```

Expected: all LiveView tests pass.

- [ ] **Step 5: Commit LiveView ingestion**

```bash
git add apps/synapsis_web/lib/synapsis_web/live/agent_live/sessions.ex apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs
git commit -m "feat(web): send chat image attachments"
```

### Task 5: Render and serialize durable image parts

**Files:**
- Modify: `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- Modify: `apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs`
- Modify: `apps/synapsis_server/lib/synapsis_server/controllers/session_controller.ex`
- Modify: `apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs`

- [ ] **Step 1: Write failing rendering and API tests**

Render `message_parts/1` with an image and assert it contains `alt="Attached image"`, `src="data:image/png;base64,..."`, responsive size constraints, `rounded-lg`, and `border-outline-variant`. Change the controller test that currently expects `%{"type" => "unknown"}` to expect `%{"type" => "image", "media_type" => "image/png", "data" => "base64data"}`.

- [ ] **Step 2: Run both focused suites and verify RED**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs
```

Expected: FAIL because `Part.Image` renders an empty div and REST reports `unknown`.

- [ ] **Step 3: Implement image presentation and serialization**

Add a `Part.Image` case in `message_parts/1` that wraps the image in the existing `chat_bubble` component and uses only DuskMoon/Tailwind design-token classes. Add an explicit `SessionController.serialize_part/1` image clause matching the existing SessionChannel JSON shape.

- [ ] **Step 4: Run both focused suites and verify GREEN**

Run the same command from Step 2. Expected: both suites pass.

- [ ] **Step 5: Commit presentation**

```bash
git add apps/synapsis_web/lib/synapsis_web/components/core_components.ex apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs apps/synapsis_server/lib/synapsis_server/controllers/session_controller.ex apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs
git commit -m "feat(web): present durable chat images"
```

### Task 6: Verify the complete attachment flow

**Files:**
- Modify only if verification exposes an in-scope defect.

- [ ] **Step 1: Run all scoped automated gates**

```bash
npm run test:hooks
npm run typecheck
devenv shell --no-tui -- mix test apps/synapsis_core/test/synapsis/image_test.exs apps/synapsis_agent/test/synapsis/session/worker_test.exs apps/synapsis_data/test/synapsis/session/pending_input_store_test.exs apps/synapsis_provider/test/synapsis/provider/message_mapper_test.exs apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs
devenv shell --no-tui -- mix format --check-formatted
git diff --check
```

Expected: every command exits 0 and all scoped tests report zero failures.

- [ ] **Step 2: Build assets**

```bash
devenv shell --no-tui -- mix duskmoon_bundler.build synapsis_web
```

Expected: JavaScript and Tailwind assets build successfully.

- [ ] **Step 3: Run a real browser proof**

Start or restart the worktree server on an unused port, attach a small PNG through the actual `Attach files` control, and send an image-only prompt. Verify all of the following:

- The outgoing LiveView event contains `images[0].data` as a Base64 string, never `{}`.
- The selected file clears only after server acceptance.
- `/api/sessions/:id` returns a user `image` part.
- The user bubble renders the image.
- With session debug enabled, the provider request contains an OpenAI-compatible `image_url` data URL (or the corresponding configured-provider image block).

- [ ] **Step 4: Review scope and history**

```bash
git status --short
git log --oneline --decorate main..HEAD
git diff --stat main...HEAD
```

Expected: only files listed in this plan changed, commits are logical, and no debug artifacts remain.

- [ ] **Step 5: Write the required agent note**

Save a note labeled `project: synapsis` describing the browser `File` JSON loss, the Base64 JSON contract, server validation limits, and the automated/browser evidence.
