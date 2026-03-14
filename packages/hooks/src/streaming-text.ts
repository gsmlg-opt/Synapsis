export const StreamingTextHook = {
  mounted() {
    this.handleEvent("append_text", ({ text }: { text: string }) => {
      this.el.textContent += text
    })
    this.handleEvent("clear_streaming", () => {
      this.el.textContent = ""
    })
  },
} as any
