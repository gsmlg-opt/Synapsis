export const SendButtonHook = {
  mounted() {
    this.el.addEventListener("click", () => {
      const input = document.getElementById("message-input") as any
      if (!input) return
      const value = (input.value || input.getAttribute("value") || "").trim()
      if (value) {
        this.pushEvent("send_message", { content: value })
        input.value = ""
        input.setAttribute("value", "")
      }
    })
  },
} as any
