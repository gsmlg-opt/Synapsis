export const MarkdownSubmitHook = {
  mounted() {
    // Hide only the Write/Preview toolbar; keep the status bar so slotted
    // footer actions (e.g. Send button in slot="bottom-end") remain visible.
    const simplifyEditor = () => {
      const root = this.el.shadowRoot
      if (root) {
        const toolbar = root.querySelector('.toolbar')
        if (toolbar) (toolbar as HTMLElement).style.display = 'none'
      }
    }
    simplifyEditor()
    requestAnimationFrame(simplifyEditor)

    this.el.addEventListener("keydown", (e: KeyboardEvent) => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        // getValue() returns the live editor content; .value is the stale property
        const value = (this.el.getValue?.() ?? this.el.value ?? "").trim()
        if (value) {
          this.pushEvent("send_message", { content: value })
          this.el.setValue?.("")
        }
      }
    })
  },
} as any
