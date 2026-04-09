import { ChatAppHook } from "./chat-app"
import { MarkdownRenderer } from "./markdown-renderer"
import { MarkdownSubmitHook } from "./markdown-submit"
import { DiffViewerHook } from "./diff-viewer"
import { TerminalOutputHook } from "./terminal-output"
import { ScrollBottomHook } from "./scroll-bottom"
import { StreamingTextHook } from "./streaming-text"
import { TextareaSubmitHook } from "./textarea-submit"

export const Hooks = {
  ChatApp: ChatAppHook,
  MarkdownRenderer,
  MarkdownSubmit: MarkdownSubmitHook,
  DiffViewer: DiffViewerHook,
  TerminalOutput: TerminalOutputHook,
  ScrollBottom: ScrollBottomHook,
  StreamingText: StreamingTextHook,
  TextareaSubmit: TextareaSubmitHook,
}

export { ChatAppHook } from "./chat-app"
export { MarkdownRenderer } from "./markdown-renderer"
export { MarkdownSubmitHook } from "./markdown-submit"
export { DiffViewerHook } from "./diff-viewer"
export { TerminalOutputHook } from "./terminal-output"
export { ScrollBottomHook } from "./scroll-bottom"
export { StreamingTextHook } from "./streaming-text"
export { TextareaSubmitHook } from "./textarea-submit"
