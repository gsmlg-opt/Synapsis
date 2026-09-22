import 'phoenix_html'
import { Socket } from 'phoenix'
import { LiveSocket } from 'phoenix_live_view'
// Register the newer markdown-input (with bottom-start/end slot support)
// BEFORE the elements umbrella, which otherwise registers an older version
// that lacks slots. customElements.define only honors the first registration.
import '@duskmoon-dev/el-markdown-input/register'
import '@duskmoon-dev/el-markdown/register'
import '@duskmoon-dev/elements/register'
import * as DuskmoonHooks from 'phoenix_duskmoon/hooks'
import { ChatImageInputHook, Hooks, observeChatInputFieldSemantics } from '@synapsis/hooks'

// WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#73
// Preserve the upstream bridge while propagating field identity into the
// nested shadow-DOM textarea used by el-dm-chat-input.
const DuskmoonWebComponentHook = DuskmoonHooks.WebComponentHook as any
const SynapsisChatImageInputHook = ChatImageInputHook as any
const WebComponentHook = {
  ...DuskmoonWebComponentHook,
  mounted(this: {
    el: HTMLElement
    fieldSemanticsObserver?: { disconnect(): void }
    observeFieldSemantics?: () => { disconnect(): void } | null
  }) {
    if (this.el.tagName === 'EL-DM-CHAT-INPUT') {
      this.observeFieldSemantics = () => observeChatInputFieldSemantics(this.el)
      SynapsisChatImageInputHook.mounted.call(this)
    } else {
      DuskmoonWebComponentHook.mounted.call(this)
    }
  },
  updated(this: { el: HTMLElement }) {
    if (this.el.tagName !== 'EL-DM-CHAT-INPUT') {
      DuskmoonWebComponentHook.updated.call(this)
    }
  },
  destroyed(this: { el: HTMLElement; fieldSemanticsObserver?: { disconnect(): void } }) {
    if (this.el.tagName === 'EL-DM-CHAT-INPUT') {
      SynapsisChatImageInputHook.destroyed.call(this)
    } else {
      DuskmoonWebComponentHook.destroyed.call(this)
    }
  }
}

// Keep theme preference client-side; Auto must follow the system on every page.
const systemTheme = window.matchMedia('(prefers-color-scheme: dark)')
const themeSelector = 'input[name="theme-mode"]'
type ThemeMode = 'auto' | 'sunshine' | 'moonlight'

function savedTheme(): ThemeMode {
  try {
    const saved = localStorage.getItem('theme')
    if (saved === 'sunshine' || saved === 'moonlight') return saved
  } catch {
    // Use Auto when browser storage is unavailable.
  }
  return 'auto'
}

let themeMode = savedTheme()

function applyTheme() {
  const theme = themeMode === 'auto' ? (systemTheme.matches ? 'moonlight' : 'sunshine') : themeMode
  document.documentElement.setAttribute('data-theme', theme)
  document.documentElement.style.colorScheme = theme === 'moonlight' ? 'dark' : 'light'
  document.querySelectorAll<HTMLInputElement>(themeSelector).forEach((input) => {
    input.checked = input.value === themeMode
  })
}

function changeTheme(event: Event) {
  const input = event.target
  if (!(input instanceof HTMLInputElement) || !input.matches(themeSelector) || !input.checked)
    return
  if (input.value !== 'auto' && input.value !== 'sunshine' && input.value !== 'moonlight') return
  themeMode = input.value
  try {
    localStorage.setItem('theme', themeMode)
  } catch {
    // Still apply the selection for this page when storage is unavailable.
  }
  applyTheme()
}

systemTheme.addEventListener('change', applyTheme)
window.addEventListener('storage', (event) => {
  if (event.key === 'theme' || event.key === null) {
    themeMode = savedTheme()
    applyTheme()
  }
})
applyTheme()

const ThemeSwitcher = {
  mounted(this: { el: HTMLElement }) {
    applyTheme()
    this.el.addEventListener('change', changeTheme)
  },
  updated() {
    applyTheme()
  },
  destroyed(this: { el: HTMLElement }) {
    this.el.removeEventListener('change', changeTheme)
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute('content') || ''

// Clear any previously memorized Phoenix longpoll fallback decision.
try {
  window.sessionStorage.removeItem('phx:fallback:LongPoll')
} catch {
  // Ignore storage access issues (private mode / disabled storage).
}

const liveSocket = new LiveSocket('/live', Socket, {
  transport: window.WebSocket,
  params: { _csrf_token: csrfToken },
  hooks: { ...DuskmoonHooks, WebComponentHook, ThemeSwitcher, ...Hooks }
})

liveSocket.connect()

// Expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
// >> liveSocket.disableLatencySim()
;(window as any).liveSocket = liveSocket
