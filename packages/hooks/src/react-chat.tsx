import React, { useEffect, useRef, useState } from 'react'
import { Chat, ComposerSettings } from '@duskmoon-dev/components/chat'
import { Markdown } from '@duskmoon-dev/components/markdown'
import { Button } from '@duskmoon-dev/components/button'
import { Form } from '@duskmoon-dev/components/form'
import { Input } from '@duskmoon-dev/components/input'
import { copyChatText } from './chat-clipboard'
import { encodeChatImages } from './chat-image-input'
import { useSynapsisChatSubmission } from './chat-submission'
import { createChatRequestId } from './chat-request-id'
import { AudioContent, ToolResultContent } from './tool-result'

type ChatProps = {
  state: { conversationId: string }
  bridge: { send(action: string, payload: Record<string, unknown>): Promise<unknown> }
  connected: boolean
  synchronizing: boolean
  active: boolean
  canSubmit: boolean
  metadata: Record<string, any>
  admission: Record<string, any>
  runtime: Record<string, any>
  message: Record<string, any>
  targetId: string
  timeline: any
}

function AttachmentPreview({ file }: { file: File }) {
  const [url, setUrl] = useState('')
  useEffect(() => {
    const preview = URL.createObjectURL(file)
    setUrl(preview)
    return () => URL.revokeObjectURL(preview)
  }, [file])
  return <span className="inline-flex items-center gap-2">
    <img src={url || undefined} alt="" className="h-10 w-10 rounded object-cover" />
    {file.name}
  </span>
}

function Tool({ tool }: { tool: Record<string, any> }) {
  const status = ['complete', 'completed'].includes(tool.status) ? 'success' : tool.status
  return <Chat.Work className={`chat-tool-${status || 'pending'}`} open={status === 'running' || status === 'error'}>
    <Chat.WorkSummary>{tool.name || tool.tool || 'Tool'} <Chat.ToolStatus>{tool.status}</Chat.ToolStatus></Chat.WorkSummary>
    <Chat.WorkBody>
      {tool.input != null && <Chat.ToolCall><pre>{JSON.stringify(tool.input, null, 2)}</pre></Chat.ToolCall>}
      {tool.display != null ? <ToolResultContent display={tool.display} /> :
        tool.result != null && <Chat.ToolResult><pre>{typeof tool.result === 'string' ? tool.result : JSON.stringify(tool.result, null, 2)}</pre></Chat.ToolResult>}
    </Chat.WorkBody>
  </Chat.Work>
}

function Part({ part }: { part: Record<string, any> }) {
  switch (part.type) {
    case 'text': return <Markdown className="chat-bubble-content" markdown={part.content || ''} />
    case 'reasoning': return <Chat.Work><Chat.WorkSummary>Thinking</Chat.WorkSummary><Chat.WorkBody><Markdown markdown={part.content || ''} /></Chat.WorkBody></Chat.Work>
    case 'image': return <img src={part.src ?? `data:${part.media_type};base64,${part.data}`} alt="Attached image" loading="lazy" decoding="async" className="max-h-96 max-w-full rounded-lg object-contain" />
    case 'delivered_image': return <figure className="min-w-0 max-w-full space-y-1">
      <img src={part.src} alt={part.filename || 'Assistant image'} loading="lazy" decoding="async" className="max-h-96 max-w-full rounded-lg object-contain" />
      <figcaption><a href={part.src} download={part.filename} className="text-sm underline">Download image</a></figcaption>
    </figure>
    case 'video': return <figure className="min-w-0 max-w-full space-y-1">
      <video controls preload="none" aria-label={part.filename || 'Assistant video'} className="block max-h-96 w-full min-w-0 max-w-full rounded-lg object-contain">
        <source src={part.src} type={part.mediaType} />
        Your browser does not support video playback.
      </video>
      <figcaption><a href={part.src} download={part.filename} className="text-sm underline">Download video</a></figcaption>
    </figure>
    case 'audio': return <AudioContent src={part.src} mediaType={part.mediaType} filename={part.filename} label={part.filename || 'Audio attachment'} />
    case 'tool_use': return <Tool tool={{ ...part, name: part.name || part.tool }} />
    case 'tool_result': return <Tool tool={{ name: 'Tool result', status: part.is_error ? 'error' : 'success', result: part.content, display: part.display }} />
    case 'file': return <details><summary>{part.path}</summary><pre>{part.content}</pre></details>
    case 'compaction': return <details><summary>{part.count} messages compacted</summary><Markdown markdown={part.summary || part.content || ''} /></details>
    default: return null
  }
}

const copyIconPath = 'M8 16H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v2M10 8h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2Z'
const copiedIconPath = 'm5 12 4 4L19 6'
const retryIconPath = 'M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6'
const messageActionIcons = new Map([
  ['edit_message', 'm14 5 5 5M5 19l4-1L20 7a1.4 1.4 0 0 0 0-2l-1-1a1.4 1.4 0 0 0-2 0L6 15l-1 4Z'],
  ['fork_message', 'M6 8v8m12-8v1a6 6 0 0 1-6 6H6M8 6a2 2 0 1 1-4 0 2 2 0 0 1 4 0Zm12 0a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM8 18a2 2 0 1 1-4 0 2 2 0 0 1 4 0Z'],
  ['retry_message', retryIconPath],
  ['regenerate', retryIconPath],
  ['dismiss_heartbeat', 'M6 6l12 12M18 6 6 18']
])

function MessageActionButton({ label, title = label, iconPath, disabled, onClick }: {
  label: string
  title?: string
  iconPath?: string
  disabled?: boolean
  onClick: () => void
}) {
  return <Button type="button" size={iconPath ? 'xs' : 'sm'} shape={iconPath ? 'square' : undefined}
    color="neutral" appearance="ghost" aria-label={label} title={title} disabled={disabled} onClick={onClick}>
    {iconPath ? <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      <path d={iconPath} />
    </svg> : label}
  </Button>
}

function Message(props: ChatProps) {
  const { message, bridge, connected, synchronizing, targetId, timeline, metadata } = props
  const [notice, setNotice] = useState('')
  const [pending, setPending] = useState(false)
  const [editText, setEditText] = useState<string | null>(null)
  const pendingAction = useRef(false)
  const meta = message.metadata || {}
  const user = message.role === 'user'
  const copied = notice === 'Copied'
  async function copy() {
    setNotice(await copyChatText(message.content) ? 'Copied' : 'Copy failed')
  }
  async function action(name: string, extra: Record<string, unknown> = {}) {
    if (pendingAction.current) return false
    pendingAction.current = true
    setPending(true)
    setNotice('')
    try {
      await bridge.send('action', { action: name, message_id: message.id, request_id: createChatRequestId(), ...extra })
      return true
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Action failed')
      return false
    } finally {
      pendingAction.current = false
      setPending(false)
    }
  }
  const disabled = !connected || synchronizing || pending
  const editAction = message.actions?.find((item: Record<string, any>) => item.id === 'edit_message')
  const editDisabled = disabled || !editAction || editAction.disabled || editAction.eligible === false
  const heartbeat = meta.heartbeat
  const codeAgent = meta.codeAgent
  if (message.role === 'assistant' && message.status === 'streaming' &&
      !message.content && !meta.reasoning && !message.tools?.length && !meta.parts?.length &&
      !meta.permissions?.length && !message.error && !heartbeat && !codeAgent) {
    return <span id={targetId} className="absolute" aria-hidden="true" />
  }
  const timestampValue = meta.timestamp || heartbeat?.timestamp
  const timestamp = timestampValue && new Date(timestampValue)
  const time = timestamp && !Number.isNaN(timestamp.getTime()) ? timestamp.toLocaleTimeString() : null
  const Row = user ? Chat : Chat.Agent
  const Content = user ? Chat.Bubble : Chat.Content
  return <Row id={targetId} timeline={timeline} {...(user ? { placement: 'end' as const } : {})} role="article" data-message-id={message.id}>
    {!user && metadata.assistantAvatar && <Chat.Avatar aria-hidden="true">{metadata.assistantAvatar}</Chat.Avatar>}
    <Chat.Header>
      <span className="font-medium">{message.author || (user ? 'You' : 'Assistant')}</span>
      {time && <time dateTime={timestampValue} className="text-xs text-on-surface-variant">{time}</time>}
      {meta.tokenCount > 0 && <span className="text-xs text-on-surface-variant">{user ? 'in' : 'out'}: {meta.tokenCount}</span>}
    </Chat.Header>
    <Content {...(user ? { color: 'primary' as const, filled: true, size: 'sm' as const, collapsible: true } : {})} streaming={message.status === 'streaming'}>
      {meta.reasoning && <Chat.Work><Chat.WorkSummary>Thinking</Chat.WorkSummary><Chat.WorkBody><Markdown markdown={meta.reasoning} /></Chat.WorkBody></Chat.Work>}
      {message.role === 'error' ? <p role="alert" className="text-error">{message.error || message.content}</p> :
        !codeAgent && (meta.parts?.length ? meta.parts.map((part: Record<string, any>, index: number) => <Part key={index} part={part} />) : <Markdown className="chat-bubble-content" markdown={message.content || ''} />)}
      {(message.tools || []).map((tool: Record<string, any>) => <Tool key={tool.id} tool={tool} />)}
      {(meta.permissions || []).map((permission: Record<string, any>) => <div key={permission.tool_use_id} className="synapsis-chat-permission">
        <p className="font-medium">{permission.tool} <span className="text-xs">{permission.level}</span></p>
        <pre>{JSON.stringify(permission.input || {}, null, 2)}</pre>
        <Chat.Actions>
          <Button size="sm" disabled={disabled} onClick={() => action('approve_tool', { tool_use_id: permission.tool_use_id })}>Approve</Button>
          <Button size="sm" appearance="ghost" disabled={disabled} onClick={() => action('deny_tool', { tool_use_id: permission.tool_use_id })}>Deny</Button>
        </Chat.Actions>
      </div>)}
      {codeAgent && <>
        <Chat.Work open={codeAgent.status === 'running'}>
          <Chat.WorkSummary>Code Agent — {codeAgent.status}</Chat.WorkSummary>
          <Chat.WorkBody>
            <p>{codeAgent.prompt}</p>
            {(codeAgent.tool_calls || []).map((tool: Record<string, any>, index: number) => <Tool key={tool.id || index} tool={tool} />)}
          </Chat.WorkBody>
        </Chat.Work>
        {codeAgent.completion && <Markdown markdown={codeAgent.completion} />}
      </>}
      {heartbeat && <span className="text-xs text-on-surface-variant">Heartbeat · {heartbeat.name}</span>}
    </Content>
    {message.error && message.role !== 'error' && <p role="alert" className="text-error">{message.error}</p>}
    <Chat.Footer>
      {editText !== null && <form className="mb-2 w-full min-w-0 space-y-2" onSubmit={async event => {
        event.preventDefault()
        if (!editDisabled && await action('edit_message', { text: editText })) setEditText(null)
      }}>
        <Input.TextArea aria-label="Edit message" value={editText} onChange={event => setEditText(event.target.value)}
          rows={3} maxLength={256000} resize="vertical" autoFocus disabled={editDisabled} />
        <div className="flex flex-wrap justify-end gap-2">
          <Button type="button" size="xs" appearance="ghost" disabled={pending} onClick={() => setEditText(null)}>Cancel</Button>
          <Button type="submit" size="xs" disabled={editDisabled}>Send in new session</Button>
        </div>
      </form>}
      <Chat.Actions hover>
        {message.content && <MessageActionButton label="Copy" title={copied ? 'Copied' : 'Copy'}
          iconPath={copied ? copiedIconPath : copyIconPath} onClick={copy} />}
        {(message.actions || []).map((item: Record<string, any>) => <MessageActionButton key={item.id}
          label={item.label} title={item.title} iconPath={messageActionIcons.get(item.id)}
          disabled={disabled || item.disabled || item.eligible === false || (item.id === 'edit_message' && editText !== null)}
          onClick={() => {
            if (item.id === 'edit_message') {
              setNotice('')
              setEditText(message.content)
            } else {
              void action(item.id)
            }
          }} />)}
      </Chat.Actions>
      <span role="status" className={notice && !copied ? 'text-xs text-on-surface-variant' : 'sr-only'}>{notice}</span>
    </Chat.Footer>
  </Row>
}

function UserQuestion({ question, bridge, connected, synchronizing }: {
  question: { ref: string, question: string, options?: { label: string, description?: string }[] | null }
  bridge: ChatProps['bridge']
  connected: boolean
  synchronizing: boolean
}) {
  const [form] = Form.useForm<{ response: string }>()
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const pending = useRef(false)
  const disabled = !connected || synchronizing || busy
  const fieldId = `question-response-${question.ref}`

  async function answer(values: { response?: string }) {
    if (disabled || pending.current) return
    pending.current = true
    setBusy(true)
    setNotice('')
    try {
      await bridge.send('action', {
        action: 'answer_question', ref: question.ref, response: values.response?.trim() || '',
        request_id: createChatRequestId()
      })
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Could not send answer')
    } finally {
      pending.current = false
      setBusy(false)
    }
  }

  return <Form form={form} layout="vertical" className="synapsis-chat-question" onFinish={answer}>
    <p className="font-medium">{question.question}</p>
    {!!question.options?.length && <div className="synapsis-chat-question-options">
      {question.options.map((option, index) => <Button key={index} type="button" size="sm" appearance="outline" disabled={disabled} onClick={() => form.setFieldValue('response', option.label)}>
        {option.label}{option.description && <span className="text-xs"> — {option.description}</span>}
      </Button>)}
    </div>}
    <Form.Item name="response" label="Your answer" htmlFor={fieldId} rules={[{
      validator: (_rule, value) => {
        if (typeof value !== 'string' || !value.trim()) throw new Error('Enter an answer')
      }
    }]}>
      <Input.TextArea id={fieldId} name="response" rows={2} resize="vertical" maxLength={256000} disabled={disabled} />
    </Form.Item>
    {notice && <p role="alert" className="text-error">{notice}</p>}
    <Button type="submit" size="sm" disabled={disabled}>{busy ? 'Sending…' : 'Submit answer'}</Button>
  </Form>
}

type QueueItem = { id: string, text: string, attachment?: { src: string, alt: string } | null, steerable: boolean }

const steerIcon = <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true" focusable="false"><path d="m15 4 5 5-5 5M20 9h-9a6 6 0 0 0-6 6v4" /></svg>
const removeIcon = <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true" focusable="false"><path d="M18 6 6 18M6 6l12 12" /></svg>

// Queued prompts are server-owned; items leave once the server starts or withdraws them.
function Queue({ items, canSteer, bridge, connected, synchronizing }: {
  items: QueueItem[]
  canSteer: boolean
  bridge: ChatProps['bridge']
  connected: boolean
  synchronizing: boolean
}) {
  const [pendingIds, setPendingIds] = useState<string[]>([])
  const [notice, setNotice] = useState('')
  async function act(action: 'steer_queued' | 'remove_queued', id: string) {
    setPendingIds(ids => [...ids, id])
    setNotice('')
    try { await bridge.send('action', { action, input_id: id }) }
    catch (error) { setNotice(error instanceof Error ? error.message : 'Queued message action failed') }
    finally { setPendingIds(ids => ids.filter(pending => pending !== id)) }
  }
  const offline = !connected || synchronizing
  return <>
    <Chat.Queue
      className="synapsis-chat-queue"
      items={items.map(({ id, text, attachment }) => ({ id, text, ...(attachment ? { attachment } : {}) }))}
      pendingIds={pendingIds}
      onSteer={id => act('steer_queued', id)}
      onRemove={id => act('remove_queued', id)}
      renderItemActions={(item, index, pending) => {
        const textOnly = items[index]?.steerable === true
        const steerable = canSteer && textOnly
        const steerTitle = steerable ? `Steer waiting message ${index + 1}` :
          textOnly ? 'Steering needs a running turn' : 'Only text messages can steer the running turn'
        return <>
          <Button size="sm" appearance="ghost" shape="circle" disabled={pending || offline || !steerable}
            aria-label={`Steer waiting message ${index + 1}`}
            title={steerTitle}
            onClick={() => act('steer_queued', item.id)}>{steerIcon}</Button>
          <Button size="sm" appearance="ghost" shape="circle" disabled={pending || offline}
            aria-label={`Remove waiting message ${index + 1}`} title={`Remove waiting message ${index + 1}`}
            onClick={() => act('remove_queued', item.id)}>{removeIcon}</Button>
        </>
      }}
    />
    {notice && <p role="alert" className="text-error synapsis-chat-status">{notice}</p>}
  </>
}

function Status({ runtime, metadata, admission, active, bridge, connected, synchronizing }: ChatProps) {
  const [notice, setNotice] = useState('')
  const questions = metadata.userQuestions || []
  const waitingForUser = questions.length > 0
  const queue: QueueItem[] = metadata.queue || []
  const voiceQueued = typeof metadata.voiceQueued === 'number' ? metadata.voiceQueued : 0
  return <>
    {queue.length > 0 && <Queue items={queue} canSteer={admission.canSteer === true} bridge={bridge} connected={connected} synchronizing={synchronizing} />}
    {voiceQueued > 0 && <p role="status" className="synapsis-chat-status">{voiceQueued} {voiceQueued === 1 ? 'message' : 'messages'} queued</p>}
    {active && <Chat.Status role="status" className="synapsis-chat-status">
      <Chat.StatusItem className="items-center gap-2 whitespace-nowrap">
        {!waitingForUser && <Chat.Typing className="min-w-0" role="presentation" aria-hidden="true" />}
        <span>{waitingForUser ? 'Waiting for your answer' : runtime.phase === 'tool_executing' ? 'Running tools…' : 'Generating…'}</span>
      </Chat.StatusItem>
    </Chat.Status>}
    {questions.map((question: any) => <UserQuestion key={question.ref} question={question} bridge={bridge} connected={connected} synchronizing={synchronizing} />)}
    {admission.canRetry && <Button size="sm" appearance="ghost" disabled={!connected || synchronizing} onClick={() => bridge.send('retry', {}).catch(error => setNotice(error.message))}>Retry</Button>}
    {notice && <p role="alert" className="text-error">{notice}</p>}
  </>
}

const contextIcons = {
  agent: 'M4 7h5l2 2h9v10H4z',
  session: 'M4 4h16v12H4z M2 20h20',
  access: 'm12 3 8 4v5c0 5-8 9-8 9s-8-4-8-9V7z M12 8v5 M12 16h.01',
}

function ContextIcon({ kind }: { kind: keyof typeof contextIcons }) {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
    strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d={contextIcons[kind]} />
  </svg>
}

function SessionContext({ metadata, connected, synchronizing, runtime }: ChatProps) {
  const phase = metadata.voiceCall ? runtime.phase : undefined
  const online = connected && (!phase || phase === 'listening' || phase === 'responding')
  const connecting = synchronizing || (connected && (phase === 'connecting' || phase === 'reconnecting' || phase === 'switching'))
  const state = connecting ? 'connecting' : online ? 'connected' : 'disconnected'
  const label = synchronizing ? 'Synchronizing' : !connected ? 'Disconnected' :
    phase ? ({ offline: 'Call offline', listening: 'Listening', responding: 'Responding', connecting: 'Connecting',
      reconnecting: 'Reconnecting', switching: 'Switching', ending: 'Ending call', error: 'Call error' }[phase as string] ?? phase) : 'Connected'

  return <Chat.ComposerContext>
    <Chat.ComposerContextItem icon={<ContextIcon kind="agent" />} title={metadata.assistantLabel}>{metadata.assistantLabel}</Chat.ComposerContextItem>
    <Chat.ComposerContextItem icon={<ContextIcon kind="session" />}>{metadata.sessionKind}</Chat.ComposerContextItem>
    <Chat.ComposerContextEnd>
      {metadata.host && <Chat.ComposerContextItem title={metadata.host}>{metadata.host}</Chat.ComposerContextItem>}
      <Chat.ComposerConnection state={state} label={label} />
    </Chat.ComposerContextEnd>
  </Chat.ComposerContext>
}

type ModelChoice = { id: string; name: string; provider: string; context_window: number }
type SessionModel = { value?: string; label: string; disabled?: boolean; choices?: ModelChoice[] }

function SessionSettings({ props, onError }: { props: ChatProps; onError: (message: string) => void }) {
  const { metadata, bridge, connected, synchronizing, state } = props
  const model: SessionModel = metadata.model
  const access: string = metadata.access
  const choices = (model.choices || []).map(choice => ({
    value: choice.id, label: choice.name, description: `${choice.provider} · ${choice.context_window} context tokens`,
  }))
  const accessDescription: Record<string, string> = {
    'Full access': 'Session permissions allow read, write, execute and destructive tool calls.',
    'Configured access': 'Tool calls follow the permission rules configured for this session.',
    'Read only': 'The agent is configured for read-only work.',
    'Read-only history': 'This conversation is available for reading.',
  }
  return <ComposerSettings variant="menu" scopeKey={state.conversationId} revision={0}
    groups={[
      { id: 'access', label: 'Access', settingIds: ['access'], appearance: 'access', icon: <ContextIcon kind="access" /> },
      { id: 'model', label: 'Session model', settingIds: ['model'], appearance: 'model' },
    ]}
    settings={[
      { id: 'access', label: 'Access', value: access, choices: [{ value: access, label: access,
        description: accessDescription[access], tone: access === 'Full access' ? 'warning' : undefined }] },
      { id: 'model', label: 'Model', value: model.value || '', choices: model.value ? choices :
        [{ value: '', label: model.label, unavailableReason: 'Current model' }, ...choices],
        unavailableReason: !model.choices || model.disabled || !connected || synchronizing ? 'Model selection is unavailable' : undefined },
    ]}
    onRequest={async request => {
      const result = { ...request, revision: request.expectedRevision }
      try {
        await bridge.send('action', { action: 'switch_model', model_id: request.value })
        onError('')
        return { ...result, outcome: 'accepted', value: request.value }
      } catch (error) {
        const message = error instanceof Error ? error.message : 'Failed to switch session model'
        onError(message)
        return { ...result, outcome: 'rejected', message }
      }
    }}
    onAcknowledged={() => { /* The LiveView snapshot supplies the selected model. */ }}
  />
}

export function createSynapsisReactChat(factory: any) {
  function Composer(props: ChatProps) {
    const { state, bridge, connected, synchronizing, active, canSubmit, metadata, admission } = props
    const [value, setValue] = useState('')
    const [files, setFiles] = useState<File[]>([])
    const [localNotice, setLocalNotice] = useState('')
    const [steering, setSteering] = useState(false)
    const { submit, busy, notice } = useSynapsisChatSubmission(props)
    const attachmentsAllowed = metadata.attachmentsAllowed === true
    const voiceCall = metadata.voiceCall === true
    const types = voiceCall
      ? ['image/png', 'image/jpeg', 'image/webp']
      : ['image/png', 'image/jpeg', 'image/gif', 'image/webp']
    function changeFiles(next: File[]) {
      const error = next.length > 4 ? 'Attach at most 4 images' :
        next.some(file => !types.includes(file.type)) ? (voiceCall ? 'Use PNG, JPEG or WebP images' : 'Use PNG, JPEG, GIF or WebP images') :
        voiceCall && next.reduce((size, file) => size + file.size, 0) > 1_300_000 ? 'Call images must total at most 1.3 MB' :
        next.some(file => file.size > 5 * 1024 * 1024) ? 'Each image must be at most 5 MiB' :
        next.reduce((size, file) => size + file.size, 0) > 10 * 1024 * 1024 ? 'Images must total at most 10 MiB' : ''
      setLocalNotice(error)
      if (!error) setFiles(next)
    }
    const stop = metadata.canStop === false ? undefined :
      () => bridge.send('stop', {}).catch(error => setLocalNotice(error.message))
    async function steer() {
      const text = value
      setSteering(true)
      setLocalNotice('')
      try { await bridge.send('action', { action: 'steer', text }); setValue(current => current === text ? '' : current) }
      catch (error) { setLocalNotice(error instanceof Error ? error.message : 'Could not steer session') }
      finally { setSteering(false) }
    }

    return <Chat.Composer
      className={metadata.kind === 'agent' ? 'synapsis-session-composer chat-composer-ghost' : undefined}
      context={metadata.kind === 'agent' && <SessionContext {...props} />}
      compact={metadata.kind === 'agent'}
      scope={{ contextKey: 'synapsis-agent-session', conversationId: state.conversationId }}
      value={value}
      onValueChange={setValue}
      attachments={files}
      onAttachmentsChange={attachmentsAllowed ? changeFiles : undefined}
      accept={types.join(',')}
      allowAttachmentOnly={attachmentsAllowed}
      disabled={!connected || synchronizing}
      canSubmit={canSubmit}
      busy={busy || steering}
      generating={active}
      minRows={metadata.kind === 'agent' ? 2 : 1}
      maxRows={8}
      error={localNotice || notice || undefined}
      sendLabel={admission.sendLabel || (active && attachmentsAllowed ? 'Queue' : 'Send')}
      stopLabel="Stop"
      attachLabel={admission.canSteer ? 'Add files or manage turn' : 'Attach images'}
      addMenu={metadata.kind === 'agent' && active && stop && <>
        {admission.canSteer && <button type="button" className="popover-menu-item"
          disabled={!canSubmit || busy || steering || !value.trim() || files.length > 0}
          onClick={event => { event.currentTarget.closest<HTMLElement>('[popover]')?.hidePopover(); void steer() }}>Steer</button>}
        <button type="button" className="popover-menu-item" disabled={!connected || synchronizing}
          onClick={event => { event.currentTarget.closest<HTMLElement>('[popover]')?.hidePopover(); void stop() }}>Stop</button>
      </>}
      textareaProps={{ name: 'content', 'aria-label': 'Message', placeholder: voiceCall && !admission.canSubmit ? 'Start a call to send a message…' : 'Write a message…', title: 'Send with Ctrl/Cmd+Enter', onPaste: event => {
        if (!attachmentsAllowed) return
        const pasted = Array.from(event.clipboardData.files).filter(file => file.type.startsWith('image/'))
        if (pasted.length) { event.preventDefault(); changeFiles([...files, ...pasted]) }
      } }}
      renderAttachment={(file, { remove, disabled }) => <>
        <AttachmentPreview file={file} />
        <Button size="sm" appearance="ghost" disabled={disabled} aria-label={`Remove ${file.name}`} onClick={remove}>Remove</Button>
      </>}
      onSubmit={async ({ value: text, files: attachments }) => {
        setLocalNotice('')
        try {
          const images = attachmentsAllowed ? await encodeChatImages(attachments) : []
          await submit({ text, images })
          return true
        } catch (error) {
          setLocalNotice(error instanceof Error ? error.message : 'Could not read image attachment')
          return false
        }
      }}
      onStop={stop}
    >
      {metadata.kind === 'agent' && <SessionSettings props={props} onError={setLocalNotice} />}
    </Chat.Composer>
  }
  return factory({ Composer, renderMessage: Message, renderStatus: Status })
}
