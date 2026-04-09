export const StreamingTextHook = {
  mounted() {
    this._buffer = ""
    this.handleEvent("append_text", ({ text }: { text: string }) => {
      this._buffer += text
      this.el.setAttribute("content", this._buffer)
    })
    this.handleEvent("clear_streaming", () => {
      this._buffer = ""
      this.el.setAttribute("content", "")
    })
  },
} as any
