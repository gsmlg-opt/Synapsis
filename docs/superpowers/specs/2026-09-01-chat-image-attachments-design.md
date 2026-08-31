# Chat Image Attachments Design

## Context

`el-dm-chat-input` 1.7.4 emits a `send` event with `{value, files}`, but the
current Phoenix DuskMoon bridge forwards the browser `File` objects unchanged.
Phoenix serializes LiveView events with JSON, so each `File` becomes `{}`. The
LiveView handler then reads only `value` and calls the text-only
`Sessions.send_message/2` path. The durable user message and provider request
therefore contain no image part.

## Goals

- Send images selected in the existing DuskMoon chat input to LiveView as Base64
  in a normal JSON payload.
- Validate the decoded image on the server before it becomes a durable
  `Synapsis.Part.Image`.
- Preserve image parts through session persistence and the existing provider
  mappers.
- Render sent images in LiveView history and serialize them from the REST session
  endpoint.
- Keep selected files when validation or delivery fails; clear them only after
  the server accepts the message.

## Non-goals

- PDF, document, archive, audio, video, or arbitrary-file ingestion.
- Multipart uploads, temporary server files, blob storage, or upload progress.
- Changes to provider wire formats; the current Anthropic, OpenAI-compatible,
  and Google message mappers already support `Synapsis.Part.Image`.
- Provider capability discovery or automatic model switching.

## Client Contract

The chat input uses a Synapsis-owned LiveView hook instead of forwarding the
DuskMoon `send` event through the generic `WebComponentHook`. The hook reads the
current `File[]`, converts every file to Base64, and pushes this JSON-safe shape:

```json
{
  "value": "Describe this image",
  "images": [
    {
      "name": "diagram.png",
      "media_type": "image/png",
      "data": "iVBORw0KGgo..."
    }
  ]
}
```

`data` contains only Base64 bytes, not a `data:` URL. `name` is display metadata
and is not used to trust the media type. The hook reports file-read failures to
LiveView and leaves the editor and selected files unchanged. On an accepted
server reply it clears both text and files through the chat input's public
methods.

The existing plain-text behavior remains valid: an empty `images` list is sent
when no files are selected. An image-only prompt is allowed even when `value` is
blank.

## Server Validation

`Synapsis.Image` gains a JSON payload decoder that returns validated
`Synapsis.Part.Image` structs. Validation is authoritative on the server:

- At most four images per message.
- At most 5 MiB decoded bytes per image.
- At most 10 MiB decoded bytes across one message.
- Supported media types: PNG, JPEG, WebP, and GIF.
- Base64 must decode strictly.
- The declared media type must match the decoded magic bytes.
- Empty, malformed, unsupported, or oversized images reject the whole message.

The decoder never writes the image to disk. Error values are stable atoms plus a
safe user-facing message; raw Base64 is never logged.

## LiveView and Session Flow

`AgentLive.Sessions` accepts `%{"value" => content, "images" => images}`. It
validates the payload before optimistic rendering and passes the resulting image
parts directly to `Session.Worker.send_message/3` through a new in-memory image
part clause in `Synapsis.Sessions`. The existing path-based image API remains for
CLI and REST compatibility.

Optimistic user messages contain text and image parts. If the session is already
running, the same parts are stored in `PendingInputStore` and begin the next turn
without changing ordering. A rejected payload produces a flash error, does not
start or queue a turn, and tells the client hook not to clear its files.

Once accepted, existing code persists the text plus image parts atomically in the
turn and the existing provider mapper emits the provider-specific multimodal
content. For an image-only prompt, persistence omits the empty text part so the
provider receives only valid image blocks; text extraction for memory context
continues to fall back to an empty string.

## Rendering and API Output

`CoreComponents.message_parts/1` renders `Synapsis.Part.Image` as an image with
an inline `data:<media_type>;base64,<data>` source, constrained to the chat bubble
width and carrying descriptive fallback text from the original filename when
available. Since `Part.Image` currently has no filename field, the first version
uses `"Attached image"` as alt text and does not change the persisted part schema.

`SessionController.serialize_part/1` returns image parts as:

```json
{"type":"image","media_type":"image/png","data":"iVBORw0KGgo..."}
```

The SessionChannel already uses that shape and remains unchanged.

## Error Handling

- Client read failure: show an error, retain text and files, send nothing.
- Invalid Base64, type mismatch, unsupported format, count limit, or size limit:
  reject the whole message and retain text and files.
- Session send/queue failure: retain text and files and restore durable messages.
- Success: clear text and files after the LiveView event acknowledgement.
- No path silently falls back to a text-only request when images were selected.

## Testing

- TypeScript unit tests for Base64 conversion, JSON payload shape, image-only
  submission, successful clearing, and failure retention.
- `Synapsis.Image` unit tests for valid PNG/JPEG/WebP/GIF payloads, malformed
  Base64, magic-byte mismatch, unsupported types, count, per-image size, and
  aggregate size.
- LiveView tests proving image parts reach `Sessions`/the worker, persist, queue,
  reject atomically, and render.
- REST controller tests proving image serialization.
- Existing provider mapper tests proving a persisted image becomes the expected
  provider payload.
- TypeScript typecheck, hook tests, focused Elixir suites, asset build, and a
  browser run that attaches a real image and observes an image part in both the
  session API and provider debug request.

## Scope Boundaries

Implementation is limited to the image hook, image validation, the Agent session
LiveView, message rendering, session serialization, and focused tests. It does
not change provider configuration, model selection, workspace attachments, or
unrelated DuskMoon components.
