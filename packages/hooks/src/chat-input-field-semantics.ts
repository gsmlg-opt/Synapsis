export function syncChatInputFieldSemantics(element: HTMLElement) {
  if (element.tagName !== "EL-DM-CHAT-INPUT") return

  const markdownInput = element.shadowRoot?.querySelector<HTMLElement>("el-dm-markdown-input")
  const textarea = markdownInput?.shadowRoot?.querySelector<HTMLTextAreaElement>("textarea")

  if (!textarea) return

  if (element.id) textarea.id = `${element.id}-editor`

  const name = element.getAttribute("name")
  if (name) textarea.setAttribute("name", name)
}

type FieldSemanticsObserver = Pick<MutationObserver, "disconnect" | "observe">
type FieldSemanticsObserverFactory = (callback: () => void) => FieldSemanticsObserver

export function observeChatInputFieldSemantics(
  element: HTMLElement,
  createObserver: FieldSemanticsObserverFactory = (callback) => new MutationObserver(callback),
) {
  if (element.tagName !== "EL-DM-CHAT-INPUT" || !element.shadowRoot) return null

  syncChatInputFieldSemantics(element)

  const observer = createObserver(() => syncChatInputFieldSemantics(element))
  observer.observe(element.shadowRoot, { childList: true, subtree: true })
  return observer
}
