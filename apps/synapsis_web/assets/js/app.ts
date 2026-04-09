import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import "@duskmoon-dev/elements/register"
import "@duskmoon-dev/el-markdown/register"
import "@duskmoon-dev/el-markdown-input/register"
import { Hooks } from "@synapsis/hooks"

// Client-only theme switcher — upstream hook pushes "theme_changed" to the
// server which has no handler, causing a disconnect flash. We handle
// everything on the client: localStorage + data-theme on <html>.
const ThemeSwitcher = {
  mounted(this: { el: HTMLElement }) {
    const saved = localStorage.getItem("theme")
    if (saved) {
      document.documentElement.setAttribute("data-theme", saved)
    }

    const controllers = this.el.querySelectorAll<HTMLInputElement>(".theme-controller")
    const current = saved || this.el.dataset.theme || "default"

    controllers.forEach((c) => {
      c.checked = c.value === current
      c.addEventListener("change", () => {
        localStorage.setItem("theme", c.value)
        document.documentElement.setAttribute("data-theme", c.value)
      })
    })
  },

  updated(this: { el: HTMLElement }) {
    const saved = localStorage.getItem("theme")
    if (saved) {
      this.el.querySelectorAll<HTMLInputElement>(".theme-controller").forEach((c) => {
        c.checked = c.value === saved
      })
    }
  },
}

const csrfToken =
  document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

// Clear any previously memorized Phoenix longpoll fallback decision.
try {
  window.sessionStorage.removeItem("phx:fallback:LongPoll")
} catch {
  // Ignore storage access issues (private mode / disabled storage).
}

const liveSocket = new LiveSocket("/live", Socket, {
  transport: window.WebSocket,
  params: { _csrf_token: csrfToken },
  hooks: { ThemeSwitcher, ...Hooks },
})

liveSocket.connect()

// Expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
// >> liveSocket.disableLatencySim()
;(window as any).liveSocket = liveSocket
