export const MarkdownSubmitHook = {
  mounted() {
    this.el.addEventListener("keydown", (e: KeyboardEvent) => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        const value = (this.el.value || this.el.getAttribute("value") || "").trim()
        if (value) {
          this.pushEvent("send_message", { content: value })
          this.el.value = ""
          this.el.setAttribute("value", "")
        }
      }
    })
  },
} as any
