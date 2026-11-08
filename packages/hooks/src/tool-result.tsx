import React from 'react'
import { Chat } from '@duskmoon-dev/components/chat'

type ToolResultBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; src: string; mediaType: string; alt: string; metadata?: unknown }
  | { type: 'audio'; src: string; mediaType: string; filename: string }
  | { type: 'link'; kind: 'diffs-viewer' | 'diffs-file'; label: string; href: string; expiresAt: string; filename?: string; mediaType?: string; bytes?: number }
  | { type: 'json'; label: string; value: unknown }
  | { type: 'reference' | 'unsupported'; kind: string; label: string; value: unknown; uri?: string; text?: string }

export type ToolResultDisplay = {
  blocks?: ToolResultBlock[]
  sidecars?: { key: string; label: string; value: unknown }[]
  error?: { class: string; message: string; details?: unknown } | null
  isError?: boolean
  displayError?: { class: string; message: string }
}

function JsonValue({ label, value }: { label: string; value: unknown }) {
  return <details className="min-w-0 max-w-full">
    <summary className="cursor-pointer text-sm font-medium">{label}</summary>
    <pre className="max-h-96 overflow-auto whitespace-pre-wrap break-words text-xs">{JSON.stringify(value, null, 2)}</pre>
  </details>
}

export function AudioContent({ src, mediaType, filename, label = 'Tool result audio' }: {
  src: string; mediaType: string; filename: string; label?: string
}) {
  return <div className="min-w-0 max-w-full space-y-1">
    {mediaType === 'application/octet-stream' ? <p className="text-sm text-on-surface-variant">
      This audio format cannot be played here. Download the original audio file.
    </p> : <audio controls preload="none" aria-label={label} className="block w-full min-w-0 max-w-full">
      <source src={src} type={mediaType} />
      Your browser does not support audio playback.
    </audio>}
    <a href={src} download={filename} className="text-sm underline">Download audio</a>
  </div>
}

function Block({ block }: { block: ToolResultBlock }) {
  switch (block.type) {
    case 'text':
      return <pre className="max-w-full overflow-auto whitespace-pre-wrap break-words">{block.text}</pre>
    case 'image':
      return <figure className="min-w-0 max-w-full">
        <img src={block.src} alt={block.alt} loading="lazy" decoding="async" className="max-h-96 max-w-full rounded-lg object-contain" />
        {block.metadata != null && <JsonValue label="Image metadata" value={block.metadata} />}
      </figure>
    case 'audio':
      return <AudioContent src={block.src} mediaType={block.mediaType} filename={block.filename} />
    case 'link':
      return <div className="min-w-0 max-w-full space-y-1" data-tool-content-kind={block.kind}>
        <a href={block.href} download={block.filename} target={block.kind === 'diffs-viewer' ? '_blank' : undefined} rel="noreferrer" className="text-sm underline">{block.label}</a>
        <p className="text-xs text-on-surface-variant">
          {block.kind === 'diffs-file' && <span>{block.mediaType === 'application/pdf' ? 'PDF' : 'PNG'} · {block.bytes?.toLocaleString()} bytes · </span>}
          <time dateTime={block.expiresAt}>Expires {new Date(block.expiresAt).toLocaleString()}</time>
        </p>
      </div>
    case 'reference':
    case 'unsupported':
      return <div className="min-w-0 max-w-full" data-tool-content-kind={block.kind}>
        <p className="text-sm font-medium text-on-surface-variant">{block.label}</p>
        {block.uri && <pre className="whitespace-pre-wrap break-words text-sm">{block.uri}</pre>}
        {block.text && <pre className="whitespace-pre-wrap break-words text-sm">{block.text}</pre>}
        <JsonValue label="Metadata" value={block.value} />
      </div>
    case 'json':
      return <JsonValue label={block.label} value={block.value} />
  }
}

export function ToolResultContent({ display }: { display: ToolResultDisplay }) {
  return <Chat.ToolResult className="min-w-0 max-w-full space-y-2" data-tool-result-error={display.isError || undefined}>
    {display.displayError && <p role="alert" className="text-error">{display.displayError.message} ({display.displayError.class})</p>}
    {display.error && <div role="alert" className="space-y-2 text-error">
      <p>{display.error.message} ({display.error.class})</p>
      {display.error.details != null && <JsonValue label="Error details" value={display.error.details} />}
    </div>}
    {(display.blocks || []).map((block, index) => <Block key={index} block={block} />)}
    {(display.sidecars || []).map(sidecar => <JsonValue key={sidecar.key} label={sidecar.label} value={sidecar.value} />)}
  </Chat.ToolResult>
}
