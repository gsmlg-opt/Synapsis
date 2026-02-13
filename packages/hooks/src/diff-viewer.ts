import { createRoot, type Root } from "react-dom/client"
import { createElement } from "react"
import { DiffViewer } from "@synapsis/ui"

interface DiffViewerHookInstance {
  el: HTMLElement
  root: Root | null
}

export const DiffViewerHook = {
  mounted(this: DiffViewerHookInstance) {
    this.root = createRoot(this.el)
    this.render()
  },

  updated(this: DiffViewerHookInstance) {
    this.render()
  },

  destroyed(this: DiffViewerHookInstance) {
    this.root?.unmount()
  },

  render(this: DiffViewerHookInstance) {
    const oldContent = this.el.dataset.oldContent || ""
    const newContent = this.el.dataset.newContent || ""
    const filename = this.el.dataset.filename
    this.root?.render(createElement(DiffViewer, { oldContent, newContent, filename }))
  },
}
