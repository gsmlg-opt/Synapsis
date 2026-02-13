import { createRoot, type Root } from "react-dom/client"
import { createElement } from "react"
import { MarkdownView } from "@synapsis/ui"

interface MarkdownRendererInstance {
  el: HTMLElement
  root: Root | null
}

export const MarkdownRenderer = {
  mounted(this: MarkdownRendererInstance) {
    this.root = createRoot(this.el)
    this.render()
  },

  updated(this: MarkdownRendererInstance) {
    this.render()
  },

  destroyed(this: MarkdownRendererInstance) {
    this.root?.unmount()
  },

  render(this: MarkdownRendererInstance) {
    const content = this.el.dataset.content || ""
    this.root?.render(createElement(MarkdownView, { content }))
  },
}
