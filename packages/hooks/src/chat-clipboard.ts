export async function copyChatText(text: string, page: Document = document): Promise<boolean> {
  const clipboard = page.defaultView?.navigator.clipboard
  if (clipboard?.writeText) {
    try {
      await clipboard.writeText(text)
      return true
    } catch {
      // The browser can reject this API even on a secure origin.
    }
  }

  // On ordinary HTTP, copy the selection within the original click gesture.
  const previousFocus = page.activeElement as HTMLElement | null
  const field = page.createElement('textarea')
  field.value = text
  field.readOnly = true
  field.tabIndex = -1
  Object.assign(field.style, { position: 'fixed', top: '0', left: '0', opacity: '0', pointerEvents: 'none' })

  try {
    page.body.append(field)
    field.focus({ preventScroll: true })
    field.setSelectionRange(0, field.value.length)
    return page.execCommand?.('copy') ?? false
  } catch {
    return false
  } finally {
    field.remove()
    previousFocus?.focus?.({ preventScroll: true })
  }
}
