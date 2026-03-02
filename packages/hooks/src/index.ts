import { ChatAppHook } from "./chat-app"
import { MarkdownRenderer } from "./markdown-renderer"
import { DiffViewerHook } from "./diff-viewer"
import { TerminalOutputHook } from "./terminal-output"
import { ScrollBottomHook } from "./scroll-bottom"

export const Hooks = {
  ChatApp: ChatAppHook,
  MarkdownRenderer,
  DiffViewer: DiffViewerHook,
  TerminalOutput: TerminalOutputHook,
  ScrollBottom: ScrollBottomHook,
}

export { ChatAppHook } from "./chat-app"
export { MarkdownRenderer } from "./markdown-renderer"
export { DiffViewerHook } from "./diff-viewer"
export { TerminalOutputHook } from "./terminal-output"
export { ScrollBottomHook } from "./scroll-bottom"
