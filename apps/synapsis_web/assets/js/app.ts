import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
// @ts-ignore — no type declarations for this JS module
import { ThemeSwitcher as UpstreamThemeSwitcher } from "../../../../deps/phoenix_duskmoon/assets/js/hooks/theme_switcher.js"
import "@duskmoon-dev/elements/register"

// Wrap upstream hook to actually apply data-theme to <html>
const ThemeSwitcher = {
  ...UpstreamThemeSwitcher,
  mounted() {
    // Restore theme from localStorage before upstream init
    const saved = localStorage.getItem("theme")
    if (saved) {
      document.documentElement.setAttribute("data-theme", saved)
    }

    UpstreamThemeSwitcher.mounted.call(this)

    // Listen for theme changes and apply to <html>
    this.el.querySelectorAll(".theme-controller").forEach((controller: HTMLInputElement) => {
      controller.addEventListener("change", () => {
        const theme = controller.value
        document.documentElement.setAttribute("data-theme", theme)
      })
    })
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
  hooks: { ThemeSwitcher },
})

liveSocket.connect()

// Expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
// >> liveSocket.disableLatencySim()
;(window as any).liveSocket = liveSocket
