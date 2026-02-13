import { createRoot, type Root } from "react-dom/client"
import { createElement } from "react"
import { TerminalOutput } from "@synapsis/ui"

interface TerminalOutputHookInstance {
  el: HTMLElement
  root: Root | null
}

export const TerminalOutputHook = {
  mounted(this: TerminalOutputHookInstance) {
    this.root = createRoot(this.el)
    this.render()
  },

  updated(this: TerminalOutputHookInstance) {
    this.render()
  },

  destroyed(this: TerminalOutputHookInstance) {
    this.root?.unmount()
  },

  render(this: TerminalOutputHookInstance) {
    const content = this.el.dataset.content || ""
    const exitCode = this.el.dataset.exitCode
      ? parseInt(this.el.dataset.exitCode, 10)
      : undefined
    this.root?.render(createElement(TerminalOutput, { content, exitCode }))
  },
}
