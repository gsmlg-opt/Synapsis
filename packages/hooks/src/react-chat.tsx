import React, { useEffect, useRef, useState } from 'react'
import { Chat } from '@duskmoon-dev/components/chat'
import { Markdown } from '@duskmoon-dev/components/markdown'
import { Button } from '@duskmoon-dev/components/button'
import { Form } from '@duskmoon-dev/components/form'
import { Input } from '@duskmoon-dev/components/input'
import { encodeChatImages } from './chat-image-input'
import { useSynapsisChatSubmission } from './chat-submission'
import { createChatRequestId } from './chat-request-id'

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
  return <Chat.Tool status={status || 'pending'} open={status === 'running' || status === 'error'}>
    <Chat.ToolHeader>{tool.name || tool.tool || 'Tool'} <Chat.ToolStatus>{tool.status}</Chat.ToolStatus></Chat.ToolHeader>
    {tool.input != null && <Chat.ToolCall><pre>{JSON.stringify(tool.input, null, 2)}</pre></Chat.ToolCall>}
    {tool.result != null && <Chat.ToolResult><pre>{typeof tool.result === 'string' ? tool.result : JSON.stringify(tool.result, null, 2)}</pre></Chat.ToolResult>}
  </Chat.Tool>
}

function Part({ part }: { part: Record<string, any> }) {
  switch (part.type) {
    case 'text': return <Markdown className="chat-bubble-content" markdown={part.content || ''} />
    case 'reasoning': return <Chat.Reasoning><summary>Thinking</summary><Markdown markdown={part.content || ''} /></Chat.Reasoning>
    case 'image': return <img src={`data:${part.media_type};base64,${part.data}`} alt="Attached image" loading="lazy" decoding="async" className="max-h-96 max-w-full rounded-lg object-contain" />
    case 'tool_use': return <Tool tool={{ ...part, name: part.name || part.tool }} />
    case 'tool_result': return <Chat.Tool status={part.is_error ? 'error' : 'success'}><Chat.ToolHeader>Tool result</Chat.ToolHeader><Chat.ToolResult><pre>{part.content}</pre></Chat.ToolResult></Chat.Tool>
    case 'file': return <details><summary>{part.path}</summary><pre>{part.content}</pre></details>
    case 'compaction': return <details><summary>{part.count} messages compacted</summary><Markdown markdown={part.summary || part.content || ''} /></details>
    default: return null
  }
}

function Message(props: ChatProps) {
  const { message, bridge, connected, synchronizing, targetId, timeline, metadata } = props
  const [notice, setNotice] = useState('')
  const [pending, setPending] = useState(false)
  const meta = message.metadata || {}
  const user = message.role === 'user'
  async function action(name: string, extra: Record<string, unknown> = {}) {
    setPending(true)
    setNotice('')
    try { await bridge.send('action', { action: name, message_id: message.id, ...extra }) }
    catch (error) { setNotice(error instanceof Error ? error.message : 'Action failed') }
    finally { setPending(false) }
  }
  const disabled = !connected || synchronizing || pending
  const queued = meta.queued
  const heartbeat = meta.heartbeat
  const codeAgent = meta.codeAgent
  const timestampValue = meta.timestamp || heartbeat?.timestamp
  const timestamp = timestampValue && new Date(timestampValue)
  const time = timestamp && !Number.isNaN(timestamp.getTime()) ? timestamp.toLocaleTimeString() : null
  return <Chat id={targetId} timeline={timeline} placement={user ? 'end' : 'start'} role="article" data-message-id={message.id}>
    {!user && metadata.assistantAvatar && <Chat.Avatar aria-hidden="true">{metadata.assistantAvatar}</Chat.Avatar>}
    <Chat.Header>
      <span className="font-medium">{message.author || (user ? 'You' : 'Assistant')}</span>
      {time && <time dateTime={timestampValue} className="text-xs text-on-surface-variant">{time}</time>}
      {meta.tokenCount > 0 && <span className="text-xs text-on-surface-variant">{user ? 'in' : 'out'}: {meta.tokenCount}</span>}
      {queued && <span className="text-xs text-on-surface-variant">Queued</span>}
    </Chat.Header>
    <Chat.Bubble color={user ? 'primary' : undefined} filled={user} size="sm" streaming={message.status === 'streaming'}>
      {meta.reasoning && <Chat.Reasoning><summary>Thinking</summary><Markdown markdown={meta.reasoning} /></Chat.Reasoning>}
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
      {codeAgent && <details open={codeAgent.status === 'running'}>
        <summary>Code Agent — {codeAgent.status}</summary>
        <p>{codeAgent.prompt}</p>
        {(codeAgent.tool_calls || []).map((tool: Record<string, any>, index: number) => <Tool key={tool.id || index} tool={tool} />)}
        {codeAgent.completion && <Markdown markdown={codeAgent.completion} />}
      </details>}
      {heartbeat && <span className="text-xs text-on-surface-variant">Heartbeat · {heartbeat.name}</span>}
    </Chat.Bubble>
    {message.error && message.role !== 'error' && <p role="alert" className="text-error">{message.error}</p>}
    <Chat.Footer>
      <Chat.Actions hover>
        {message.content && <Button size="sm" appearance="ghost" onClick={async () => {
          try { await navigator.clipboard.writeText(message.content); setNotice('Copied') }
          catch { setNotice('Copy failed') }
        }}>Copy</Button>}
        {(message.actions || []).map((item: Record<string, any>) => <Button key={item.id} size="sm" appearance="ghost" disabled={disabled || item.disabled || item.eligible === false} onClick={() => action(item.id)}>{item.label}</Button>)}
      </Chat.Actions>
      {notice && <span role="status" className="text-xs text-on-surface-variant">{notice}</span>}
    </Chat.Footer>
  </Chat>
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

function Status({ runtime, metadata, admission, active, bridge, connected, synchronizing }: ChatProps) {
  const [notice, setNotice] = useState('')
  const questions = metadata.userQuestions || []
  const waitingForUser = questions.length > 0
  return <>
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

export function createSynapsisReactChat(factory: any) {
  function Composer(props: ChatProps) {
    const { bridge, connected, synchronizing, active, canSubmit, metadata, admission } = props
    const [value, setValue] = useState('')
    const [files, setFiles] = useState<File[]>([])
    const [localNotice, setLocalNotice] = useState('')
    const [steering, setSteering] = useState(false)
    const { submit, busy, notice } = useSynapsisChatSubmission(props)
    const attachmentsAllowed = metadata.attachmentsAllowed === true
    function changeFiles(next: File[]) {
      const types = ['image/png', 'image/jpeg', 'image/gif', 'image/webp']
      const error = next.length > 4 ? 'Attach at most 4 images' :
        next.some(file => !types.includes(file.type)) ? 'Use PNG, JPEG, GIF or WebP images' :
        next.some(file => file.size > 5 * 1024 * 1024) ? 'Each image must be at most 5 MiB' :
        next.reduce((size, file) => size + file.size, 0) > 10 * 1024 * 1024 ? 'Images must total at most 10 MiB' : ''
      setLocalNotice(error)
      if (!error) setFiles(next)
    }
    return <Chat.Composer
      className="synapsis-chat-composer"
      value={value}
      onValueChange={setValue}
      attachments={files}
      onAttachmentsChange={attachmentsAllowed ? changeFiles : undefined}
      accept="image/png,image/jpeg,image/gif,image/webp"
      allowAttachmentOnly={attachmentsAllowed}
      disabled={!connected || synchronizing}
      canSubmit={canSubmit}
      busy={busy || steering}
      generating={active}
      minRows={3}
      maxRows={8}
      error={localNotice || notice || undefined}
      sendLabel={admission.sendLabel || (active && attachmentsAllowed ? 'Queue' : 'Send')}
      stopLabel="Stop"
      attachLabel="Attach images"
      textareaProps={{ name: 'content', 'aria-label': 'Message', placeholder: 'Send a message… (Ctrl/Cmd+Enter)', onPaste: event => {
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
      onStop={metadata.canStop === false ? undefined : () => bridge.send('stop', {}).catch(error => setLocalNotice(error.message))}
    >
      {admission.canSteer && <Button size="sm" appearance="ghost" disabled={!canSubmit || busy || steering || !value.trim() || files.length > 0} onClick={async () => {
        const text = value
        setSteering(true)
        setLocalNotice('')
        try { await bridge.send('action', { action: 'steer', text }); setValue(current => current === text ? '' : current) }
        catch (error) { setLocalNotice(error instanceof Error ? error.message : 'Could not steer session') }
        finally { setSteering(false) }
      }}>Steer</Button>}
    </Chat.Composer>
  }
  return factory({ Composer, renderMessage: Message, renderStatus: Status })
}
