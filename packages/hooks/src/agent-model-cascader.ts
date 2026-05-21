type CascaderChangeDetail = {
  value?: unknown
  path?: unknown
}

type CascaderElement = HTMLElement & {
  value?: unknown
  _parseValue?: () => void
  update?: () => void
}

function pathFromValue(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.map(String)
  }

  if (typeof value !== "string" || value.trim() === "") {
    return []
  }

  try {
    const parsed = JSON.parse(value)
    return Array.isArray(parsed) ? parsed.map(String) : []
  } catch {
    return []
  }
}

function cascaderValue(element: CascaderElement): unknown {
  if (typeof element.value === "string" && element.value.trim() !== "") {
    return element.value
  }

  return element.getAttribute("value") ?? element.value
}

export const AgentModelCascaderHook = {
  mounted(this: any) {
    this.handleChange = (event: Event) => {
      const detail = (event as CustomEvent<CascaderChangeDetail>).detail
      const path = pathFromValue(detail?.path)
      this.syncFromPath(path.length > 0 ? path : pathFromValue(detail?.value), true)
    }

    this.syncFromElement(false)
    this.el.addEventListener("change", this.handleChange)
    this.el.addEventListener("dm-change", this.handleChange)
  },

  updated(this: any) {
    this.syncFromElement(false)
  },

  destroyed(this: any) {
    this.el.removeEventListener("change", this.handleChange)
    this.el.removeEventListener("dm-change", this.handleChange)
  },

  syncFromElement(this: any, notify: boolean) {
    this.syncFromPath(pathFromValue(cascaderValue(this.el)), notify)
  },

  syncFromPath(this: any, path: string[], notify: boolean) {
    this.syncCascaderDisplay(path)
    this.syncInputs(path, notify)
  },

  syncCascaderDisplay(this: any, path: string[]) {
    const value = path.length > 0 ? JSON.stringify(path) : ""
    const cascader = this.el as CascaderElement

    if (cascader.value !== value) {
      cascader.value = value
    }

    cascader._parseValue?.()
    cascader.update?.()
  },

  syncInputs(this: any, path: string[], notify: boolean) {
    const providerInput = document.getElementById(
      this.el.dataset.providerInput || ""
    ) as HTMLInputElement | null
    const modelInput = document.getElementById(
      this.el.dataset.modelInput || ""
    ) as HTMLInputElement | null

    if (!providerInput || !modelInput) {
      return
    }

    providerInput.value = path[0] || ""
    modelInput.value = path[1] || ""

    if (notify) {
      providerInput.dispatchEvent(new Event("change", { bubbles: true }))
    }
  },
} as any
