import { useEffect, useRef, useState } from 'react'
import { createChatRequestId } from './chat-request-id'

type SubmissionProps = {
  bridge: { send(action: string, payload: Record<string, unknown>): Promise<unknown> }
  canSubmit: boolean
}

// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#198
// The published submission helper requires secure-context crypto.randomUUID.
export function useSynapsisChatSubmission({ bridge, canSubmit }: SubmissionProps) {
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const pending = useRef(false)
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => { alive.current = false }
  }, [])

  async function submit(payload: Record<string, unknown>) {
    if (!canSubmit || pending.current) throw new Error('Chat is not accepting messages')
    pending.current = true
    setBusy(true)
    setNotice('')
    try {
      return await bridge.send('send', { ...payload, request_id: createChatRequestId() })
    } catch (error) {
      if (alive.current) setNotice(error instanceof Error ? error.message : 'Chat request failed')
      throw error
    } finally {
      pending.current = false
      if (alive.current) setBusy(false)
    }
  }
  return { submit, busy, notice }
}
