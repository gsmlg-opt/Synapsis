export const SendButtonHook = {
  mounted() {
    this.el.addEventListener("click", () => {
      const input = document.getElementById("message-input") as any
      if (!input) return
      // getValue() returns the live editor content; .value is the stale property
      const value = (input.getValue?.() ?? input.value ?? "").trim()
      if (value) {
        this.pushEvent("send_message", { content: value })
        input.setValue?.("")
      }
    })
  },
} as any
